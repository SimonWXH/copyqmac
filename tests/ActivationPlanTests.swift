// Activation: the ordered action list every activation runs, for every
// combination of the History ▸ Activation switches.
//
// The recorder below is the stub the acceptance asks for: it appends each step
// as the pipeline reaches it, so a wrong order or a missing step fails the test
// the same way it would fail in the app.

import AppKit
import Foundation

/// Records the activation steps instead of touching the pasteboard, the
/// previous app, the window, or the store.
private final class ActivationRecorder {
    private(set) var steps: [ActivationAction] = []
    /// What the paste step reports: true means the item arrived in the app.
    var pasteArrives = true
    /// What the focus step reports.
    var focusSucceeds = true
    /// The `willPaste` flag the copy step was called with.
    private(set) var copyWillPaste: [Bool] = []

    func handlers() -> ActivationHandlers {
        ActivationHandlers(
            copy: { [unowned self] willPaste in
                self.steps.append(.copy)
                self.copyWillPaste.append(willPaste)
            },
            paste: { [unowned self] completion in
                self.steps.append(.paste)
                completion(self.pasteArrives)
            },
            focusPreviousApp: { [unowned self] in
                self.steps.append(.focusPreviousApp)
                return self.focusSucceeds
            },
            closeWindow: { [unowned self] in self.steps.append(.closeWindow) },
            moveToTop: { [unowned self] in self.steps.append(.moveToTop) }
        )
    }

    /// Runs one activation and returns the steps it took.
    static func run(_ actions: [ActivationAction], configure: (ActivationRecorder) -> Void = { _ in }) -> [ActivationAction] {
        let recorder = ActivationRecorder()
        configure(recorder)
        ActivationPipeline.run(actions, handlers: recorder.handlers())
        return recorder.steps
    }
}

/// The expectation written out the way the preferences describe it: copy first,
/// then each switch in its fixed place.
private func expectedActions(
    _ options: ActivationOptions,
    hasPreviousTarget: Bool = true
) -> [ActivationAction] {
    var expected: [ActivationAction] = [.copy]
    if options.paste { expected.append(.paste) }
    if options.focusPreviousApp { expected.append(.focusPreviousApp) }
    let delivers = options.paste || options.focusPreviousApp
    if options.closeWindow, hasPreviousTarget || !delivers { expected.append(.closeWindow) }
    if options.moveToTop { expected.append(.moveToTop) }
    return expected
}

private func options(_ bits: Int) -> ActivationOptions {
    ActivationOptions(
        singleClickActivates: bits & 1 != 0,
        paste: bits & 2 != 0,
        focusPreviousApp: bits & 4 != 0,
        closeWindow: bits & 8 != 0,
        moveToTop: bits & 16 != 0
    )
}

func registerActivationPlanTests() {
    TestRunner.currentSuite = "Activation"

    TestRunner.add("every switch combination produces the expected ordered action list") {
        for bits in 0..<32 {
            let options = options(bits)
            let plan = ActivationPlan.actions(for: options, hasPreviousTarget: true)
            let expected = expectedActions(options)
            expectEqual(plan, expected, "plan for switches \(bits)")

            let recorded = ActivationRecorder.run(plan)
            expectEqual(recorded, expected, "recorded steps for switches \(bits)")
        }
    }

    TestRunner.add("single click off only selects; Return, a double click, and the menu always activate") {
        var off = ActivationOptions.defaultValue
        off.singleClickActivates = false
        expectEqual(off.singleClickActivates, false)

        var policy = ClickActivationPolicy(doubleClickInterval: 0.5)
        expectEqual(policy.shouldActivate(row: 0, clickCount: 1, at: 0.0, singleClickActivates: off.singleClickActivates), false)
        expectEqual(policy.shouldActivate(row: 0, clickCount: 2, at: 0.1, singleClickActivates: off.singleClickActivates), true)

        var on = off
        on.singleClickActivates = true
        expectEqual(on.singleClickActivates, true)
        policy.reset()
        expectEqual(policy.shouldActivate(row: 0, clickCount: 1, at: 0.0, singleClickActivates: on.singleClickActivates), true)
    }

    TestRunner.add("the defaults are today's behaviour") {
        let defaults = ActivationOptions.defaultValue
        expectEqual(defaults.singleClickActivates, false, "a click only selects")
        expectEqual(defaults.paste, true, "activating pastes")
        expectEqual(defaults.focusPreviousApp, true, "pasting focuses the previous app")
        expectEqual(defaults.closeWindow, true, "activating closes the window")
        expectEqual(defaults.moveToTop, false, "activating leaves the item where it is")
        expectEqual(Preferences.defaultValue.activation, defaults)
        expectEqual(ActivationPlan.order, [.copy, .paste, .focusPreviousApp, .closeWindow, .moveToTop])
    }

    TestRunner.add("paste off still focuses the previous app when that switch is on") {
        var options = ActivationOptions.defaultValue
        options.paste = false
        options.focusPreviousApp = true
        options.closeWindow = false
        options.moveToTop = false
        expectEqual(
            ActivationRecorder.run(ActivationPlan.actions(for: options, hasPreviousTarget: true)),
            [.copy, .focusPreviousApp]
        )
    }

    TestRunner.add("close off keeps the window open but still moves the item to the top") {
        var options = ActivationOptions.defaultValue
        options.closeWindow = false
        options.moveToTop = true
        expectEqual(
            ActivationRecorder.run(ActivationPlan.actions(for: options, hasPreviousTarget: true)),
            [.copy, .paste, .focusPreviousApp, .moveToTop]
        )
    }

    TestRunner.add("move to top is the last step, after closing the window") {
        var options = ActivationOptions.defaultValue
        options.moveToTop = true
        expectEqual(
            ActivationRecorder.run(ActivationPlan.actions(for: options, hasPreviousTarget: true)),
            [.copy, .paste, .focusPreviousApp, .closeWindow, .moveToTop]
        )
    }

    TestRunner.add("a delivery that does not arrive keeps the window open for the notice") {
        var options = ActivationOptions.defaultValue
        options.moveToTop = true
        let plan = ActivationPlan.actions(for: options, hasPreviousTarget: true)
        expectEqual(
            ActivationRecorder.run(plan) { $0.pasteArrives = false },
            [.copy, .paste, .moveToTop],
            "no Accessibility trust: the paste reports copied-only, so nothing closes or steals focus"
        )
    }

    TestRunner.add("a focus that fails keeps the window open") {
        var options = ActivationOptions.defaultValue
        options.paste = false
        options.closeWindow = true
        options.moveToTop = true
        let plan = ActivationPlan.actions(for: options, hasPreviousTarget: true)
        expectEqual(
            ActivationRecorder.run(plan) { $0.focusSucceeds = false },
            [.copy, .focusPreviousApp, .moveToTop]
        )
    }

    TestRunner.add("closing the window without a previous app keeps the entry visible") {
        var options = ActivationOptions.defaultValue
        options.closeWindow = true
        expectEqual(
            ActivationPlan.actions(for: options, hasPreviousTarget: false),
            [.copy, .paste, .focusPreviousApp],
            "a delivery with no target must not hide the notice that explains it"
        )

        // A copy-only activation has nothing to deliver, so closing is fine.
        options.paste = false
        options.focusPreviousApp = false
        expectEqual(
            ActivationPlan.actions(for: options, hasPreviousTarget: false),
            [.copy, .closeWindow]
        )
    }

    TestRunner.add("the copy step leaves the clipboard write to the paste step") {
        let recorder = ActivationRecorder()
        ActivationPipeline.run(
            ActivationPlan.actions(for: .defaultValue, hasPreviousTarget: true),
            handlers: recorder.handlers()
        )
        expectEqual(recorder.copyWillPaste, [true], "a paste follows, so the copy step does not write twice")

        var copyOnly = ActivationOptions.defaultValue
        copyOnly.paste = false
        copyOnly.focusPreviousApp = false
        let copyRecorder = ActivationRecorder()
        ActivationPipeline.run(
            ActivationPlan.actions(for: copyOnly, hasPreviousTarget: true),
            handlers: copyRecorder.handlers()
        )
        expectEqual(copyRecorder.copyWillPaste, [false], "with no paste the copy step writes the clipboard")
    }

    TestRunner.add("an older preferences blob keeps today's activation defaults") {
        let legacy = """
        {"hotKeyKeyCode":9,"hotKeyModifiers":2048,"hotKeyDisplayLabel":"\\u2325V","defaultMaxItems":1000,"searchAllTabs":false}
        """
        do {
            let decoded = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
            expectEqual(decoded.activation, ActivationOptions.defaultValue)
        } catch {
            TestRunner.fail("decoding a preferences blob without activation threw \(error)")
        }
    }

    TestRunner.add("move to top refreshes the entry's place in its tab") {
        do {
            let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
            let tab = try history.defaultTab()
            let first = try history.addItem(withText: "first", in: tab, at: Date(timeIntervalSince1970: 1_000))
            let second = try history.addItem(withText: "second", in: tab, at: Date(timeIntervalSince1970: 2_000))
            let third = try history.addItem(withText: "third", in: tab, at: Date(timeIntervalSince1970: 3_000))
            expectEqual(try history.recent(tabID: tab.id).map(\.id), [third.id, second.id, first.id])

            try history.moveToTop(first.id, at: Date(timeIntervalSince1970: 4_000))
            expectEqual(try history.recent(tabID: tab.id).map(\.id), [first.id, third.id, second.id])
            expectEqual(try history.store.entry(id: first.id)?.note, "", "the entry keeps its own state")
        } catch {
            TestRunner.fail("move to top threw \(error)")
        }
    }
}

// MARK: - The app's own activation path

/// The real model and paste service, on a private pasteboard, so the wiring
/// from the switches to the paste service, the window, and the store is
/// exercised without a window server, a target app, or synthetic input.
@MainActor
private final class ActivationFixture {
    let model: AppModel
    let pasteboard: NSPasteboard
    let entryIDs: [Int64]

    init(texts: [String]) throws {
        let history = ClipboardHistory(store: try ClipboardStore(inMemory: true))
        let pasteboard = NSPasteboard(name: .init("copyqmac-activation-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let watcher = ClipboardWatcher(history: history, pasteboard: pasteboard)
        let service = PasteService(
            tracker: FrontmostAppTracker(),
            watcher: watcher,
            pasteboard: pasteboard,
            requestTrust: { false }
        )
        let model = AppModel(history: history, isAccessibilityTrusted: { false })
        model.attach(pasteService: service)
        model.bootstrap()

        var entryIDs: [Int64] = []
        for text in texts {
            let outcome = try history.record([Fixtures.text(text)])
            guard case .inserted(let entry) = outcome else { continue }
            entryIDs.append(entry.id)
        }
        model.reload()
        self.model = model
        self.pasteboard = pasteboard
        self.entryIDs = entryIDs
    }

    func activate(_ index: Int, dismiss: @escaping () -> Void) {
        model.select(entryIDs[index])
        model.activate(entryIDs[index], dismiss: dismiss)
    }

    @discardableResult
    func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

func registerActivationPathTests() {
    TestRunner.currentSuite = "ActivationPath"

    TestRunner.add("activation with paste off copies, keeps the window open, and moves the item to the top") {
        MainActor.assumeIsolated {
            do {
                let fixture = try ActivationFixture(texts: ["first", "second", "third"])
                fixture.model.setActivation { options in
                    options.singleClickActivates = false
                    options.paste = false
                    options.focusPreviousApp = false
                    options.closeWindow = false
                    options.moveToTop = true
                }
                var dismissed = false
                fixture.activate(0) { dismissed = true }

                expect(
                    fixture.waitUntil { fixture.pasteboard.string(forType: .string) == "first" },
                    "the entry reaches the pasteboard"
                )
                expectEqual(dismissed, false, "close is off, so the window stays open")
                expectNil(fixture.model.notice, "a copy-only activation has nothing to report")
                expectEqual(
                    fixture.model.entries.first?.id,
                    fixture.entryIDs[0],
                    "move to top puts the activated item first"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a copy-only activation still closes the window when there is no previous app") {
        MainActor.assumeIsolated {
            do {
                let fixture = try ActivationFixture(texts: ["only"])
                fixture.model.setActivation { options in
                    options.paste = false
                    options.focusPreviousApp = false
                    options.closeWindow = true
                    options.moveToTop = false
                }
                var dismissed = false
                fixture.activate(0) { dismissed = true }
                expectEqual(dismissed, true, "nothing had to be delivered, so the window may close")
                expect(
                    fixture.waitUntil { fixture.pasteboard.string(forType: .string) == "only" },
                    "the entry still reaches the pasteboard"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
