// Paste-back lifecycle: a pending copy or paste must not be dropped by the
// window hiding, while a newer user action still supersedes an older one.

import AppKit
import Foundation

@MainActor
private final class PasteTestTrustGate {
    var requestTrustResult: Bool
    var isTrustedResult: Bool
    private(set) var trustRequests = 0
    private(set) var checks = 0

    init(requestTrust: Bool, isTrusted: Bool) {
        self.requestTrustResult = requestTrust
        self.isTrustedResult = isTrusted
    }

    func requestTrust() -> Bool {
        trustRequests += 1
        return requestTrustResult
    }

    func isTrusted() -> Bool {
        checks += 1
        return isTrustedResult
    }
}

@MainActor
private final class PasteTestFixture {
    let model: AppModel
    let pasteboard: NSPasteboard
    let service: PasteService
    let entryIDs: [Int64]

    convenience init(texts: [String], trustGate: PasteTestTrustGate? = nil) throws {
        try self.init(entries: texts.map { [Fixtures.text($0)] }, trustGate: trustGate)
    }

    init(entries: [[Flavour]], trustGate: PasteTestTrustGate? = nil) throws {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let pasteboard = NSPasteboard(name: .init("copyqmac-paste-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let watcher = ClipboardWatcher(history: history, pasteboard: pasteboard)
        let gate = trustGate ?? PasteTestTrustGate(requestTrust: false, isTrusted: false)
        let service = PasteService(
            tracker: FrontmostAppTracker(),
            watcher: watcher,
            pasteboard: pasteboard,
            requestTrust: { gate.requestTrust() }
        )
        let model = AppModel(history: history, isAccessibilityTrusted: { gate.isTrusted() })
        model.attach(pasteService: service)
        model.bootstrap()

        var entryIDs: [Int64] = []
        for flavours in entries {
            let outcome = try history.record(flavours)
            guard case .inserted(let entry) = outcome else {
                throw PasteTestError.duplicateFixture(flavours.map(\.type).joined(separator: ","))
            }
            entryIDs.append(entry.id)
        }
        model.reload(capturedEntryID: entryIDs.last)
        self.model = model
        self.pasteboard = pasteboard
        self.service = service
        self.entryIDs = entryIDs
    }

    func select(_ index: Int) {
        model.select(entryIDs[index])
    }

    func waitForPasteboard(_ text: String, timeout: TimeInterval = 2) {
        waitUntil({ pasteboard.string(forType: .string) == text }, timeout: timeout)
    }

    func drain(_ interval: TimeInterval) {
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    @discardableResult
    func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private enum PasteTestError: Error {
    case duplicateFixture(String)
}

func registerPasteServiceTests() {
    TestRunner.add("a pending copy reaches the pasteboard after the window hides") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PasteTestFixture(texts: ["copy survives hide"])
                fixture.model.copySelected()
                fixture.model.windowDidHide()
                fixture.waitForPasteboard("copy survives hide")
                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "copy survives hide",
                    "hiding must not cancel an explicit copy"
                )
                expectEqual(fixture.service.writeCount, 1, "the copy must reach the pasteboard exactly once")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a pending paste reaches the pasteboard after the window hides") {
        MainActor.assumeIsolated {
            do {
                let fixture = try PasteTestFixture(texts: ["paste survives hide"])
                fixture.model.pasteSelected(dismiss: {})
                fixture.model.windowDidHide()
                fixture.waitForPasteboard("paste survives hide")
                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "paste survives hide",
                    "hiding must not cancel an explicit paste"
                )
                expectEqual(fixture.service.writeCount, 1, "the paste must reach the pasteboard exactly once")
                expectNotNil(fixture.model.notice, "an untrusted paste reports why it only copied")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("hiding cancels the selected preview decode") {
        MainActor.assumeIsolated {
            do {
                let image = Flavour(itemIndex: 0, type: PasteboardTypes.png, data: Fixtures.pngData)
                let fixture = try PasteTestFixture(entries: [[image]])
                fixture.model.windowDidShow()
                fixture.model.windowDidHide()
                fixture.drain(0.3)
                expectNil(fixture.model.selectedPreviewImage, "a decode in flight when the window hides must not arrive")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a newer user action supersedes an older paste or copy") {
        MainActor.assumeIsolated {
            do {
                let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)
                guard let compressed = QtCompression.compress(payload) else {
                    TestRunner.fail("could not build the slow superseded fixture")
                    return
                }
                let older = Flavour(
                    itemIndex: 0,
                    type: PasteboardTypes.tiff,
                    rawData: compressed,
                    isCompressed: true
                )
                let fixture = try PasteTestFixture(entries: [[older], [Fixtures.text("newer action")]])
                fixture.select(0)
                fixture.model.copySelected()
                fixture.select(1)
                fixture.model.copySelected()
                fixture.waitForPasteboard("newer action")
                fixture.drain(0.5)
                expectEqual(
                    fixture.pasteboard.string(forType: .string),
                    "newer action",
                    "the newest request must win over an older one"
                )
                expectEqual(fixture.service.writeCount, 1, "the superseded request must not write the pasteboard")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a copied-only paste retires the permission notice once trust is granted") {
        MainActor.assumeIsolated {
            do {
                let gate = PasteTestTrustGate(requestTrust: false, isTrusted: false)
                let fixture = try PasteTestFixture(texts: ["trust follows the paste"], trustGate: gate)

                var expectedChecks = gate.checks + 1
                fixture.model.pasteSelected(dismiss: {})
                expect(
                    fixture.waitUntil({ gate.checks >= expectedChecks }, timeout: 2),
                    "the first paste attempt finishes"
                )
                expectEqual(gate.trustRequests, 1, "one paste attempt asks for trust exactly once")
                expectEqual(fixture.model.accessibilityGranted, false)
                expectEqual(AccessibilityNoticePolicy.isPermissionNotice(fixture.model.notice), true)

                gate.requestTrustResult = false
                gate.isTrustedResult = true
                expectedChecks = gate.checks + 1
                fixture.model.pasteSelected(dismiss: {})
                expect(
                    fixture.waitUntil({ gate.checks >= expectedChecks }, timeout: 2),
                    "the second paste attempt finishes"
                )
                expectEqual(gate.trustRequests, 2, "the next paste attempt checks again")
                expectEqual(fixture.model.accessibilityGranted, true, "the model follows the fresh check")
                expectNil(
                    fixture.model.notice,
                    "a copied-only paste must not re-show the permission notice once the app is trusted"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a refresh after the grant retires the permission notice without prompting") {
        MainActor.assumeIsolated {
            do {
                let gate = PasteTestTrustGate(requestTrust: false, isTrusted: false)
                let fixture = try PasteTestFixture(texts: ["grant clears the notice"], trustGate: gate)
                let expectedChecks = gate.checks + 1
                fixture.model.pasteSelected(dismiss: {})
                expect(
                    fixture.waitUntil({ gate.checks >= expectedChecks }, timeout: 2),
                    "the paste attempt finishes"
                )
                expectEqual(AccessibilityNoticePolicy.isPermissionNotice(fixture.model.notice), true)

                gate.isTrustedResult = true
                fixture.model.refreshAccessibilityStatus()

                expectEqual(fixture.model.accessibilityGranted, true)
                expectNil(fixture.model.notice, "a granted permission clears the stale notice")
                expectEqual(gate.trustRequests, 1, "a UI refresh must never prompt")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
