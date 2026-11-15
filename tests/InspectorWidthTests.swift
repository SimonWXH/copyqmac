// SPDX-License-Identifier: GPL-3.0-or-later
//
// InspectorWidthTests.swift
//
// Headless tests for Layout B inspector column width persistence, clamping,
// geometric drag calculation, and debounced commit behavior.

import Foundation

func registerInspectorWidthTests() {
    TestRunner.currentSuite = "InspectorWidth"

    // MARK: - Clamping and Constraints

    TestRunner.add("InspectorColumnLayout clamping enforces 240...560 range") {
        expectEqual(InspectorColumnLayout.defaultWidth, 280)
        expectEqual(InspectorColumnLayout.minWidth, 240)
        expectEqual(InspectorColumnLayout.maxWidth, 560)
        expectEqual(InspectorColumnLayout.minItemListWidth, 320)

        // Below minimum
        expectEqual(InspectorColumnLayout.clampWidth(239), 240)
        expectEqual(InspectorColumnLayout.clampWidth(100), 240)
        expectEqual(InspectorColumnLayout.clampWidth(0), 240)
        expectEqual(InspectorColumnLayout.clampWidth(-50), 240)

        // Above maximum
        expectEqual(InspectorColumnLayout.clampWidth(561), 560)
        expectEqual(InspectorColumnLayout.clampWidth(750), 560)
        expectEqual(InspectorColumnLayout.clampWidth(1000), 560)

        // In range
        expectEqual(InspectorColumnLayout.clampWidth(240), 240)
        expectEqual(InspectorColumnLayout.clampWidth(280), 280)
        expectEqual(InspectorColumnLayout.clampWidth(350.5), 350.5)
        expectEqual(InspectorColumnLayout.clampWidth(560), 560)
    }

    TestRunner.add("InspectorColumnLayout clamping preserves min item list width in container") {
        // Wide container (1000 pt): item list needs 320, remaining is 680, but capped at maxWidth 560
        expectEqual(InspectorColumnLayout.clampWidth(600, containerWidth: 1000), 560)
        expectEqual(InspectorColumnLayout.clampWidth(400, containerWidth: 1000), 400)

        // Medium container (700 pt): 700 - 320 = 380 max allowed inspector width
        expectEqual(InspectorColumnLayout.clampWidth(500, containerWidth: 700), 380)
        expectEqual(InspectorColumnLayout.clampWidth(380, containerWidth: 700), 380)
        expectEqual(InspectorColumnLayout.clampWidth(300, containerWidth: 700), 300)
        expectEqual(InspectorColumnLayout.clampWidth(200, containerWidth: 700), 240, "never below minWidth")

        // Tight container (500 pt): 500 - 320 = 180, but minWidth is 240, so effectiveMax is 240
        expectEqual(InspectorColumnLayout.clampWidth(350, containerWidth: 500), 240)
        expectEqual(InspectorColumnLayout.clampWidth(240, containerWidth: 500), 240)

        // Zero / unmeasured container falls back to standard clamping
        expectEqual(InspectorColumnLayout.clampWidth(300, containerWidth: 0), 300)
        expectEqual(InspectorColumnLayout.clampWidth(100, containerWidth: 0), 240)
        expectEqual(InspectorColumnLayout.clampWidth(800, containerWidth: 0), 560)
    }

    TestRunner.add("InspectorColumnLayout drag translation widens on left drag and narrows on right drag") {
        let base: Double = 280

        // Dragging left (negative translation) increases inspector width
        let draggedLeft = InspectorColumnLayout.width(baseWidth: base, translationX: -50, containerWidth: 800)
        expectEqual(draggedLeft, 330, "dragging left by 50 pt widens the column by 50 pt")

        // Dragging right (positive translation) decreases inspector width
        let draggedRight = InspectorColumnLayout.width(baseWidth: base, translationX: 30, containerWidth: 800)
        expectEqual(draggedRight, 250, "dragging right by 30 pt narrows the column by 30 pt")

        // Dragging past minWidth stops at 240
        let draggedPastMin = InspectorColumnLayout.width(baseWidth: base, translationX: 100, containerWidth: 800)
        expectEqual(draggedPastMin, 240, "cannot shrink past minWidth 240")

        // Dragging past container allowance (e.g. 600 pt container, 600 - 320 = 280 max)
        let draggedPastContainer = InspectorColumnLayout.width(baseWidth: base, translationX: -100, containerWidth: 600)
        expectEqual(draggedPastContainer, 280, "cannot expand past container item list minimum constraint")
    }

    // MARK: - Preferences Default & Serialization

    TestRunner.add("inspectorColumnWidth defaults to 280 in Preferences.defaultValue") {
        let prefs = Preferences.defaultValue
        expectEqual(prefs.inspectorColumnWidth, 280)
    }

    TestRunner.add("inspectorColumnWidth decode fallback for missing key resolves to default") {
        let json = #"{"defaultMaxItems":250,"language":"en"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.inspectorColumnWidth, 280, "missing inspectorColumnWidth must fall back to 280")
    }

    TestRunner.add("inspectorColumnWidth in json is clamped on decode") {
        let jsonLow = #"{"inspectorColumnWidth":120.0}"#
        let decodedLow = try JSONDecoder().decode(Preferences.self, from: Data(jsonLow.utf8))
        expectEqual(decodedLow.inspectorColumnWidth, 240, "sub-minimum width is clamped to 240")

        let jsonHigh = #"{"inspectorColumnWidth":850.0}"#
        let decodedHigh = try JSONDecoder().decode(Preferences.self, from: Data(jsonHigh.utf8))
        expectEqual(decodedHigh.inspectorColumnWidth, 560, "above-maximum width is clamped to 560")

        let jsonValid = #"{"inspectorColumnWidth":360.0}"#
        let decodedValid = try JSONDecoder().decode(Preferences.self, from: Data(jsonValid.utf8))
        expectEqual(decodedValid.inspectorColumnWidth, 360, "valid width is preserved")
    }

    TestRunner.add("inspectorColumnWidth survives store round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var prefs = try store.preferences()
        expectEqual(prefs.inspectorColumnWidth, 280, "fresh store defaults to 280")

        prefs.inspectorColumnWidth = 350
        try store.setPreferences(prefs)

        let reloaded = try store.preferences()
        expectEqual(reloaded.inspectorColumnWidth, 350, "persisted inspectorColumnWidth is restored")

        prefs.inspectorColumnWidth = 245
        try store.setPreferences(prefs)

        let reloadedB = try store.preferences()
        expectEqual(reloadedB.inspectorColumnWidth, 245, "updated inspectorColumnWidth is restored")
    }

    TestRunner.add("sanitized preferences clamps inspectorColumnWidth") {
        var prefs = Preferences.defaultValue
        prefs.inspectorColumnWidth = 999
        let sanitizedHigh = prefs.sanitized()
        expectEqual(sanitizedHigh.inspectorColumnWidth, 560)

        prefs.inspectorColumnWidth = 50
        let sanitizedLow = prefs.sanitized()
        expectEqual(sanitizedLow.inspectorColumnWidth, 240)
    }

    // MARK: - Draft Decision Rules

    TestRunner.add("InspectorWidthDraft records valid widths and rejects hidden or sub-min widths") {
        var draft = InspectorWidthDraft()
        expectEqual(draft.hasPendingCommit, false, "fresh draft has nothing pending")

        // Valid drag from 280 to 350
        expect(
            draft.record(measuredWidth: 350, isVisible: true, currentStoredWidth: 280),
            "recording a valid changed width schedules a commit"
        )
        expectEqual(draft.hasPendingCommit, true)
        expectEqual(draft.pendingValue, 350)

        expectEqual(draft.takeCommit(), 350, "takeCommit returns the recorded width")
        expectEqual(draft.hasPendingCommit, false, "taking commit clears pending")
        expectNil(draft.takeCommit(), "subsequent take returns nil")

        // Measurement when hidden must be rejected
        expectEqual(
            draft.record(measuredWidth: 350, isVisible: false, currentStoredWidth: 280),
            false,
            "hidden measurement is rejected"
        )
        expectEqual(draft.hasPendingCommit, false)

        // Measurement below minimum must be rejected
        expectEqual(
            draft.record(measuredWidth: 150, isVisible: true, currentStoredWidth: 280),
            false,
            "width below minimum is rejected"
        )
        expectEqual(draft.hasPendingCommit, false)
    }

    TestRunner.add("InspectorWidthDraft ignores changes within tolerance of current stored width") {
        var draft = InspectorWidthDraft()

        // Exact match
        expectEqual(
            draft.record(measuredWidth: 280, isVisible: true, currentStoredWidth: 280),
            false,
            "identical width schedules no write"
        )
        expectNil(draft.takeCommit())

        // Within 0.5 pt tolerance
        expectEqual(
            draft.record(measuredWidth: 280.3, isVisible: true, currentStoredWidth: 280),
            false,
            "sub-pixel noise schedules no write"
        )
        expectNil(draft.takeCommit())

        expectEqual(
            draft.record(measuredWidth: 279.7, isVisible: true, currentStoredWidth: 280),
            false,
            "negative sub-pixel noise schedules no write"
        )
        expectNil(draft.takeCommit())
    }

    TestRunner.add("InspectorWidthDraft clamps recorded values to allowed range") {
        var draft = InspectorWidthDraft()

        expect(
            draft.record(measuredWidth: 900, isVisible: true, currentStoredWidth: 280),
            "oversized drag schedules write"
        )
        expectEqual(draft.takeCommit(), 560, "oversized drag is clamped to max width 560")
    }

    TestRunner.add("InspectorWidthDraft keeps only the latest dragged width") {
        var draft = InspectorWidthDraft()

        expect(draft.record(measuredWidth: 300, isVisible: true, currentStoredWidth: 280))
        expect(draft.record(measuredWidth: 340, isVisible: true, currentStoredWidth: 280))
        expect(draft.record(measuredWidth: 380, isVisible: true, currentStoredWidth: 280))

        expectEqual(draft.takeCommit(), 380, "last dragged width wins")
        expectNil(draft.takeCommit())
    }

    TestRunner.add("InspectorWidthDraft cancel clears any pending commit") {
        var draft = InspectorWidthDraft()

        expect(draft.record(measuredWidth: 350, isVisible: true, currentStoredWidth: 280))
        expectEqual(draft.hasPendingCommit, true)

        draft.cancel()
        expectEqual(draft.hasPendingCommit, false)
        expectNil(draft.takeCommit())
    }

    // MARK: - Debouncer Timing and AppModel Integration

    TestRunner.add("InspectorWidthDebouncer coalesces rapid events and commits after delay") {
        var committed: [Double] = []
        MainActor.assumeIsolated {
            let debouncer = InspectorWidthDebouncer(delay: .milliseconds(40))

            debouncer.handleWidthChange(
                measuredWidth: 300,
                isVisible: true,
                currentStoredWidth: 280
            ) { width in
                committed.append(width)
            }

            debouncer.handleWidthChange(
                measuredWidth: 330,
                isVisible: true,
                currentStoredWidth: 280
            ) { width in
                committed.append(width)
            }

            debouncer.handleWidthChange(
                measuredWidth: 360,
                isVisible: true,
                currentStoredWidth: 280
            ) { width in
                committed.append(width)
            }
        }

        let start = Date()
        while Date().timeIntervalSince(start) < 0.015 {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        expectEqual(committed.isEmpty, true, "no commit occurs before debounce interval elapses")

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline && committed.isEmpty {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        expectEqual(committed.count, 1, "exactly one commit occurs")
        expectEqual(committed.first, 360, "the latest dragged width was committed")
    }

    TestRunner.add("InspectorWidthDebouncer cancels commit when inspector hides before delay") {
        var committed: [Double] = []
        MainActor.assumeIsolated {
            let debouncer = InspectorWidthDebouncer(delay: .milliseconds(40))

            debouncer.handleWidthChange(
                measuredWidth: 360,
                isVisible: true,
                currentStoredWidth: 280
            ) { width in
                committed.append(width)
            }

            // User hides the inspector before debounce fires
            debouncer.handleWidthChange(
                measuredWidth: 0,
                isVisible: false,
                currentStoredWidth: 280
            ) { width in
                committed.append(width)
            }
        }

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline && committed.isEmpty {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        expectEqual(committed.isEmpty, true, "hiding inspector cancels pending commit")
    }

    TestRunner.add("InspectorWidthDebouncer commits new width to AppModel and persists in store") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var committed = false
            var appModel: AppModel?
            try MainActor.assumeIsolated {
                let history = ClipboardHistory(store: store)
                _ = try history.defaultTab()
                let model = AppModel(history: history)
                appModel = model
                model.bootstrap()

                expectEqual(model.preferences.inspectorColumnWidth, 280)

                let debouncer = InspectorWidthDebouncer(delay: .milliseconds(30))

                debouncer.handleWidthChange(
                    measuredWidth: 350,
                    isVisible: true,
                    currentStoredWidth: model.preferences.inspectorColumnWidth
                ) { newWidth in
                    model.updatePreferences { $0.inspectorColumnWidth = newWidth }
                    committed = true
                }
            }

            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline && !committed {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            MainActor.assumeIsolated {
                guard let model = appModel else {
                    TestRunner.fail("the model was not created")
                    return
                }
                expectEqual(committed, true, "the debounced commit fired")
                expectEqual(model.preferences.inspectorColumnWidth, 350, "model preferences updated with committed width")

                do {
                    let reloaded = try store.preferences()
                    expectEqual(reloaded.inspectorColumnWidth, 350, "store persisted the new inspector width")
                } catch {
                    TestRunner.fail("threw \(error)")
                }
            }
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }
}
