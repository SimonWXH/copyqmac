// SPDX-License-Identifier: GPL-3.0-or-later
//
// SidebarWidthTests.swift
//
// Headless tests for Layout B sidebar column width persistence, clamping,
// and debounced commit behavior.

import Foundation

func registerSidebarWidthTests() {
    TestRunner.currentSuite = "SidebarWidth"

    // MARK: - Clamping and Constraints

    TestRunner.add("SidebarLayout clamping enforces 160...420 range") {
        expectEqual(SidebarLayout.defaultWidth, 200)
        expectEqual(SidebarLayout.minWidth, 160)
        expectEqual(SidebarLayout.maxWidth, 420)

        // Below minimum
        expectEqual(SidebarLayout.clampWidth(159), 160)
        expectEqual(SidebarLayout.clampWidth(100), 160)
        expectEqual(SidebarLayout.clampWidth(0), 160)
        expectEqual(SidebarLayout.clampWidth(-50), 160)

        // Above maximum
        expectEqual(SidebarLayout.clampWidth(421), 420)
        expectEqual(SidebarLayout.clampWidth(500), 420)
        expectEqual(SidebarLayout.clampWidth(1000), 420)

        // In range
        expectEqual(SidebarLayout.clampWidth(160), 160)
        expectEqual(SidebarLayout.clampWidth(200), 200)
        expectEqual(SidebarLayout.clampWidth(315.5), 315.5)
        expectEqual(SidebarLayout.clampWidth(420), 420)
    }

    // MARK: - Preferences Default & Serialization

    TestRunner.add("sidebarWidth defaults to 200 in Preferences.defaultValue") {
        let prefs = Preferences.defaultValue
        expectEqual(prefs.sidebarWidth, 200)
    }

    TestRunner.add("sidebarWidth decode fallback for missing key resolves to default") {
        let json = #"{"defaultMaxItems":250,"language":"en"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.sidebarWidth, 200, "missing sidebarWidth must fall back to 200")
    }

    TestRunner.add("sidebarWidth in json is clamped on decode") {
        let jsonLow = #"{"sidebarWidth":50.0}"#
        let decodedLow = try JSONDecoder().decode(Preferences.self, from: Data(jsonLow.utf8))
        expectEqual(decodedLow.sidebarWidth, 160, "sub-minimum width is clamped to 160")

        let jsonHigh = #"{"sidebarWidth":750.0}"#
        let decodedHigh = try JSONDecoder().decode(Preferences.self, from: Data(jsonHigh.utf8))
        expectEqual(decodedHigh.sidebarWidth, 420, "above-maximum width is clamped to 420")

        let jsonValid = #"{"sidebarWidth":320.0}"#
        let decodedValid = try JSONDecoder().decode(Preferences.self, from: Data(jsonValid.utf8))
        expectEqual(decodedValid.sidebarWidth, 320, "valid width is preserved")
    }

    TestRunner.add("sidebarWidth survives store round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var prefs = try store.preferences()
        expectEqual(prefs.sidebarWidth, 200, "fresh store defaults to 200")

        prefs.sidebarWidth = 310
        try store.setPreferences(prefs)

        let reloaded = try store.preferences()
        expectEqual(reloaded.sidebarWidth, 310, "persisted sidebarWidth is restored")

        prefs.sidebarWidth = 175
        try store.setPreferences(prefs)

        let reloadedB = try store.preferences()
        expectEqual(reloadedB.sidebarWidth, 175, "updated sidebarWidth is restored")
    }

    TestRunner.add("sanitized preferences clamps sidebarWidth") {
        var prefs = Preferences.defaultValue
        prefs.sidebarWidth = 999
        let sanitizedHigh = prefs.sanitized()
        expectEqual(sanitizedHigh.sidebarWidth, 420)

        prefs.sidebarWidth = 20
        let sanitizedLow = prefs.sanitized()
        expectEqual(sanitizedLow.sidebarWidth, 160)
    }

    // MARK: - Draft Decision Rules

    TestRunner.add("SidebarWidthDraft records valid widths and rejects collapsed or sub-min widths") {
        var draft = SidebarWidthDraft()
        expectEqual(draft.hasPendingCommit, false, "fresh draft has nothing pending")

        // Valid drag from 200 to 250
        expect(
            draft.record(measuredWidth: 250, isCollapsed: false, currentStoredWidth: 200),
            "recording a valid changed width schedules a commit"
        )
        expectEqual(draft.hasPendingCommit, true)
        expectEqual(draft.pendingValue, 250)

        expectEqual(draft.takeCommit(), 250, "takeCommit returns the recorded width")
        expectEqual(draft.hasPendingCommit, false, "taking commit clears pending")
        expectNil(draft.takeCommit(), "subsequent take returns nil")

        // Measurement when collapsed must be rejected
        expectEqual(
            draft.record(measuredWidth: 250, isCollapsed: true, currentStoredWidth: 200),
            false,
            "collapsed measurement is rejected"
        )
        expectEqual(draft.hasPendingCommit, false)

        // Measurement below minimum (e.g. during collapse animation) must be rejected
        expectEqual(
            draft.record(measuredWidth: 120, isCollapsed: false, currentStoredWidth: 200),
            false,
            "width below minimum is rejected"
        )
        expectEqual(draft.hasPendingCommit, false)
    }

    TestRunner.add("SidebarWidthDraft ignores changes within tolerance of current stored width") {
        var draft = SidebarWidthDraft()

        // Exact match
        expectEqual(
            draft.record(measuredWidth: 200, isCollapsed: false, currentStoredWidth: 200),
            false,
            "identical width schedules no write"
        )
        expectNil(draft.takeCommit())

        // Within 0.5 pt tolerance
        expectEqual(
            draft.record(measuredWidth: 200.3, isCollapsed: false, currentStoredWidth: 200),
            false,
            "sub-pixel noise schedules no write"
        )
        expectNil(draft.takeCommit())

        expectEqual(
            draft.record(measuredWidth: 199.7, isCollapsed: false, currentStoredWidth: 200),
            false,
            "negative sub-pixel noise schedules no write"
        )
        expectNil(draft.takeCommit())
    }

    TestRunner.add("SidebarWidthDraft clamps recorded values to allowed range") {
        var draft = SidebarWidthDraft()

        expect(
            draft.record(measuredWidth: 500, isCollapsed: false, currentStoredWidth: 200),
            "oversized drag schedules write"
        )
        expectEqual(draft.takeCommit(), 420, "oversized drag is clamped to max width 420")
    }

    TestRunner.add("SidebarWidthDraft keeps only the latest dragged width") {
        var draft = SidebarWidthDraft()

        expect(draft.record(measuredWidth: 220, isCollapsed: false, currentStoredWidth: 200))
        expect(draft.record(measuredWidth: 245, isCollapsed: false, currentStoredWidth: 200))
        expect(draft.record(measuredWidth: 310, isCollapsed: false, currentStoredWidth: 200))

        expectEqual(draft.takeCommit(), 310, "last dragged width wins")
        expectNil(draft.takeCommit())
    }

    TestRunner.add("SidebarWidthDraft cancel clears any pending commit") {
        var draft = SidebarWidthDraft()

        expect(draft.record(measuredWidth: 280, isCollapsed: false, currentStoredWidth: 200))
        expectEqual(draft.hasPendingCommit, true)

        draft.cancel()
        expectEqual(draft.hasPendingCommit, false)
        expectNil(draft.takeCommit())
    }

    // MARK: - Debouncer Timing and AppModel Integration

    TestRunner.add("SidebarWidthDebouncer coalesces rapid events and commits after delay") {
        MainActor.assumeIsolated {
            var committed: [Double] = []
            let debouncer = SidebarWidthDebouncer(delay: .milliseconds(40))

            debouncer.handleWidthChange(
                measuredWidth: 220,
                isCollapsed: false,
                currentStoredWidth: 200
            ) { width in
                committed.append(width)
            }

            // Rapid drag continued before delay expires
            debouncer.handleWidthChange(
                measuredWidth: 250,
                isCollapsed: false,
                currentStoredWidth: 200
            ) { width in
                committed.append(width)
            }

            debouncer.handleWidthChange(
                measuredWidth: 290,
                isCollapsed: false,
                currentStoredWidth: 200
            ) { width in
                committed.append(width)
            }

            // Pump briefly: delay (40ms) has not elapsed yet
            let start = Date()
            while Date().timeIntervalSince(start) < 0.015 {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            expectEqual(committed.isEmpty, true, "no commit occurs before debounce interval elapses")

            // Wait past the debounce delay
            let deadline = Date().addingTimeInterval(0.08)
            while Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            expectEqual(committed.count, 1, "exactly one commit occurs")
            expectEqual(committed.first, 290, "the latest dragged width was committed")
        }
    }

    TestRunner.add("SidebarWidthDebouncer cancels commit when sidebar collapses before delay") {
        MainActor.assumeIsolated {
            var committed: [Double] = []
            let debouncer = SidebarWidthDebouncer(delay: .milliseconds(40))

            debouncer.handleWidthChange(
                measuredWidth: 260,
                isCollapsed: false,
                currentStoredWidth: 200
            ) { width in
                committed.append(width)
            }

            // User collapses the sidebar before debounce fires
            debouncer.handleWidthChange(
                measuredWidth: 0,
                isCollapsed: true,
                currentStoredWidth: 200
            ) { width in
                committed.append(width)
            }

            // Wait past the debounce delay
            let deadline = Date().addingTimeInterval(0.08)
            while Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            expectEqual(committed.isEmpty, true, "collapsing cancels pending commit")
        }
    }

    TestRunner.add("SidebarWidthDebouncer commits new width to AppModel and persists in store") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                _ = try history.defaultTab()
                let model = AppModel(history: history)
                model.bootstrap()

                expectEqual(model.preferences.sidebarWidth, 200)

                let debouncer = SidebarWidthDebouncer(delay: .milliseconds(30))

                debouncer.handleWidthChange(
                    measuredWidth: 275,
                    isCollapsed: false,
                    currentStoredWidth: model.preferences.sidebarWidth
                ) { newWidth in
                    model.updatePreferences { $0.sidebarWidth = newWidth }
                }

                // Wait past debounce
                let deadline = Date().addingTimeInterval(0.07)
                while Date() < deadline {
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                expectEqual(model.preferences.sidebarWidth, 275, "model preferences updated with committed width")

                let reloaded = try store.preferences()
                expectEqual(reloaded.sidebarWidth, 275, "store persisted the new sidebar width")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}
