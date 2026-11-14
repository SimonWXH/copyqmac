// Accessibility trust: the prompt policy, the "a paste already worked" latch,
// and the notice wording for a stale grant.
//
// The regression these tests guard: after the user re-granted Accessibility
// the app kept prompting and kept showing the permission notice, because an
// ad-hoc-signed rebuild is a new binary to macOS - the System Settings switch
// still belongs to the old one, so `AXIsProcessTrusted` keeps saying no while
// the paste itself works. A posted paste therefore has to count as trust for the
// rest of the session, and the notice has to say "remove and add back", not
// "switch it on again".

import AppKit
import Foundation

@MainActor
private final class TrustGate {
    var processTrusted: Bool
    var promptTrusted: Bool
    private(set) var promptCount = 0
    private(set) var checks = 0

    init(processTrusted: Bool, promptTrusted: Bool) {
        self.processTrusted = processTrusted
        self.promptTrusted = promptTrusted
    }

    func readProcessTrusted() -> Bool {
        checks += 1
        return processTrusted
    }

    func readTrustedWithPrompt() -> Bool {
        promptCount += 1
        return promptTrusted
    }
}

@MainActor
private final class TrustFixture {
    let model: AppModel
    let pasteboard: NSPasteboard
    let trust: PasteTrust
    let gate: TrustGate
    let entryID: Int64

    init(processTrusted: Bool, promptTrusted: Bool) throws {
        let gate = TrustGate(processTrusted: processTrusted, promptTrusted: promptTrusted)
        let trust = PasteTrust(
            readProcessTrusted: { gate.readProcessTrusted() },
            readTrustedWithPrompt: { gate.readTrustedWithPrompt() }
        )
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let pasteboard = NSPasteboard(name: .init("copyqmac-trust-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let watcher = ClipboardWatcher(history: history, pasteboard: pasteboard)
        let service = PasteService(
            tracker: FrontmostAppTracker(),
            watcher: watcher,
            pasteboard: pasteboard,
            trust: trust
        )
        let model = AppModel(history: history, trust: trust)
        model.attach(pasteService: service)
        model.bootstrap()

        guard case .inserted(let entry) = try history.record([Fixtures.text("paste me")]) else {
            throw TrustFixtureError.duplicateFixture
        }
        model.reload(capturedEntryID: entry.id)
        model.select(entry.id)

        self.gate = gate
        self.trust = trust
        self.model = model
        self.pasteboard = pasteboard
        self.entryID = entry.id
    }

    @discardableResult
    func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Runs one paste attempt and waits until it wrote the pasteboard.
    func pasteAndWait() {
        let writes = pasteboard.changeCount
        model.pasteSelected(dismiss: {})
        waitUntil({ self.pasteboard.changeCount != writes })
    }
}

private enum TrustFixtureError: Error {
    case duplicateFixture
}

func registerAccessibilityTrustTests() {
    // MARK: - Prompt policy

    TestRunner.add("a trusted process is never prompted") {
        var session = PasteTrustSession()
        expectEqual(session.shouldPromptForPaste(processTrusted: true), false)
        expectEqual(session.hasPrompted, false)
    }

    TestRunner.add("the first untrusted paste asks and later ones do not") {
        var session = PasteTrustSession()
        expectEqual(session.shouldPromptForPaste(processTrusted: false), true)
        expectEqual(session.hasPrompted, true)
        expectEqual(session.shouldPromptForPaste(processTrusted: false), false)
        expectEqual(session.hasPrompted, true)
    }

    TestRunner.add("a posted paste establishes trust for the session") {
        var session = PasteTrustSession()
        _ = session.shouldPromptForPaste(processTrusted: false)
        session.notePasteSucceeded()
        expectEqual(session.isTrusted(processTrusted: false), true)
        expectEqual(session.shouldPromptForPaste(processTrusted: false), false)
        expectEqual(session.hasPrompted, false, "a successful paste forgets the pending prompt")
        expectEqual(session.grantLooksStale, false)
    }

    TestRunner.add("only a user-return check after a prompt can look stale") {
        var session = PasteTrustSession()
        session.noteTrustCheck(processTrusted: false, afterUserAction: true)
        expectEqual(session.grantLooksStale, false, "nothing was asked yet, so there is no stale grant")

        _ = session.shouldPromptForPaste(processTrusted: false)
        session.noteTrustCheck(processTrusted: false, afterUserAction: false)
        expectEqual(session.grantLooksStale, false, "a check inside a paste attempt is not a user return")

        session.noteTrustCheck(processTrusted: false, afterUserAction: true)
        expectEqual(session.grantLooksStale, true, "the user came back and macOS still says untrusted")

        session.noteTrustCheck(processTrusted: true, afterUserAction: true)
        expectEqual(session.grantLooksStale, false, "a grant clears the stale state")
    }

    TestRunner.add("the stale-grant notice replaces the first-run instruction") {
        let stale = AccessibilityNoticePolicy.permissionNotice(grantLooksStale: true)
        let firstRun = AccessibilityNoticePolicy.permissionNotice(grantLooksStale: false)
        expectEqual(AccessibilityNoticePolicy.isPermissionNotice(stale), true)
        expectEqual(AccessibilityNoticePolicy.isPermissionNotice(firstRun), true)
        expectNotEqual(stale, firstRun)
        expect(
            stale.contains("remove it with \u{2212}"),
            "the stale notice must tell the user to remove the old entry"
        )
        expect(
            stale.contains("add /Applications/CopyQmac.app back with +"),
            "the stale notice must tell the user to add the current binary back"
        )
        expect(
            stale.contains("untrusted"),
            "the stale notice must explain that macOS does not trust this build"
        )
        expect(
            !firstRun.contains("switch CopyQmac off and on again"),
            "toggling the stale switch does not transfer the grant, so the notice must not suggest it"
        )
    }

    // MARK: - Model and paste path

    TestRunner.add("a successful paste retires the notice and keeps it retired") {
        MainActor.assumeIsolated {
            do {
                // The process check stays stale: System Settings shows the old
                // build switched on while macOS refuses this one.
                let fixture = try TrustFixture(processTrusted: false, promptTrusted: false)
                fixture.model.notice = AccessibilityNoticePolicy.pasteNeedsPermission
                expectEqual(fixture.model.accessibilityGranted, false)

                // The paste path posted its synthetic Command-V.
                fixture.model.handlePasteOutcome(.pasted(targetName: "TextEdit"))

                expectNil(fixture.model.notice, "a paste that worked must not leave the notice up")
                expectEqual(
                    fixture.model.accessibilityGranted,
                    true,
                    "a posted paste is evidence that the app may paste"
                )
                expectEqual(fixture.trust.isEstablished, true)

                // A window activation re-reads the process-level check, which
                // still (wrongly) reports untrusted.
                fixture.model.refreshAccessibilityStatus()
                expectNil(fixture.model.notice, "the notice must stay retired across activations")
                expectEqual(fixture.model.accessibilityGranted, true)
                expectEqual(fixture.gate.promptCount, 0, "an established session never prompts")

                // Later activations keep the notice cleared even while AX reads untrusted
                fixture.model.refreshAccessibilityStatus()
                expectNil(fixture.model.notice, "the notice stays cleared on later activations")
                expectEqual(fixture.model.accessibilityGranted, true)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("no system prompt is requested when the process is already trusted") {
        MainActor.assumeIsolated {
            do {
                let fixture = try TrustFixture(processTrusted: true, promptTrusted: true)
                fixture.pasteAndWait()
                expectEqual(fixture.gate.promptCount, 0, "a trusted process must never see the dialog")
                expectEqual(fixture.gate.checks > 0, true, "trust was read to decide")
                expectEqual(fixture.model.accessibilityGranted, true)
                expectEqual(
                    AccessibilityNoticePolicy.isPermissionNotice(fixture.model.notice),
                    false,
                    "a trusted paste must not report a missing permission"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("an untrusted paste asks once and explains the copy-only result") {
        MainActor.assumeIsolated {
            do {
                let fixture = try TrustFixture(processTrusted: false, promptTrusted: false)
                fixture.pasteAndWait()
                expectEqual(fixture.gate.promptCount, 1, "the first paste asks the system once")
                expectEqual(
                    fixture.model.notice,
                    AccessibilityNoticePolicy.pasteNeedsPermission,
                    "the first notice is the first-run instruction"
                )

                fixture.pasteAndWait()
                expectEqual(fixture.gate.promptCount, 1, "a second paste in the same stretch does not ask again")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a re-check after the prompt turns the notice into the stale-grant text") {
        MainActor.assumeIsolated {
            do {
                let fixture = try TrustFixture(processTrusted: false, promptTrusted: false)
                fixture.pasteAndWait()
                expectEqual(fixture.gate.promptCount, 1)
                expectEqual(
                    fixture.model.notice,
                    AccessibilityNoticePolicy.pasteNeedsPermission,
                    "first untrusted paste shows first-run instruction"
                )

                // The user goes to System Settings and comes back; macOS still
                // reports this build as untrusted.
                fixture.model.refreshAccessibilityStatus()
                expectEqual(fixture.trust.isStaleGrant, true)
                expectEqual(
                    fixture.model.notice,
                    AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant,
                    "activation must switch displayed notice to stale-grant text immediately"
                )
                expectEqual(fixture.gate.promptCount, 1, "the activation check must not ask the system again")

                fixture.pasteAndWait()
                expectEqual(
                    fixture.model.notice,
                    AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant,
                    "the notice must distinguish a stale grant instead of repeating itself"
                )
                expectEqual(fixture.gate.promptCount, 1, "the notice change must not ask the system again")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("grant affordance switches the displayed notice to the stale-grant text") {
        MainActor.assumeIsolated {
            do {
                let fixture = try TrustFixture(processTrusted: false, promptTrusted: false)
                fixture.model.notice = AccessibilityNoticePolicy.pasteNeedsPermission
                fixture.model.grantAccessibility()
                expectEqual(fixture.trust.isStaleGrant, true)
                expectEqual(
                    fixture.model.notice,
                    AccessibilityNoticePolicy.pasteNeedsPermissionStaleGrant,
                    "grant affordance must switch displayed notice to stale-grant text"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a grant after the prompt clears the notice without another prompt") {
        MainActor.assumeIsolated {
            do {
                let fixture = try TrustFixture(processTrusted: false, promptTrusted: false)
                fixture.pasteAndWait()
                expectNotNil(fixture.model.notice)

                fixture.gate.processTrusted = true
                fixture.model.refreshAccessibilityStatus()
                expectNil(fixture.model.notice, "a real grant retires the notice")
                expectEqual(fixture.model.accessibilityGranted, true)

                fixture.pasteAndWait()
                expectEqual(fixture.gate.promptCount, 1, "the granted process is not prompted")
                expectEqual(
                    AccessibilityNoticePolicy.isPermissionNotice(fixture.model.notice),
                    false,
                    "the granted process must not be told to grant again"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("the grant affordance does not ask again once trust is established") {
        MainActor.assumeIsolated {
            do {
                let fixture = try TrustFixture(processTrusted: false, promptTrusted: false)
                fixture.model.handlePasteOutcome(.pasted(targetName: "TextEdit"))
                expectEqual(fixture.model.accessibilityGranted, true)

                fixture.model.grantAccessibility()
                expectEqual(fixture.gate.promptCount, 0, "an established session must not prompt from the button")
                expectNil(fixture.model.notice)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
