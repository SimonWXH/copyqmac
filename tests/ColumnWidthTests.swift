// SPDX-License-Identifier: GPL-3.0-or-later
//
// ColumnWidthTests.swift
//
// Headless tests for the shared Layout B column width draft and debouncer.
// The sidebar and inspector differ only in their limits and container
// clamping, so each rule is exercised against both layouts.

import Foundation

func registerColumnWidthTests() {
    TestRunner.currentSuite = "ColumnWidth"

    // MARK: - Draft Decision Rules

    TestRunner.add("shared width draft rules hold for both column layouts") {
        exerciseColumnWidthDraft(
            SidebarLayout.self,
            name: "sidebar",
            current: 200,
            changed: 250,
            belowMin: 120,
            aboveMax: 500,
            clampedAboveMax: 260,
            containerWidth: 0
        )
        exerciseColumnWidthDraft(
            InspectorColumnLayout.self,
            name: "inspector",
            current: 280,
            changed: 350,
            belowMin: 150,
            aboveMax: 900,
            clampedAboveMax: 560,
            containerWidth: 0
        )
    }

    TestRunner.add("shared width draft keeps a commit when a clamped drag repeats its final frame") {
        var sidebar = ColumnWidthDraft<SidebarLayout>()
        expect(sidebar.record(measuredWidth: 260, isVisible: true, currentStoredWidth: 200, containerWidth: 0))
        expect(
            sidebar.record(measuredWidth: 260, isVisible: true, currentStoredWidth: 200, containerWidth: 0),
            "sidebar: a repeated clamped frame must not cancel the scheduled commit"
        )
        expectEqual(sidebar.takeCommit(), 260, "sidebar: releasing against the clamp still commits the width")

        var inspector = ColumnWidthDraft<InspectorColumnLayout>()
        expect(inspector.record(measuredWidth: 560, isVisible: true, currentStoredWidth: 280, containerWidth: 1000))
        expectEqual(inspector.pendingValue, 560)
        expect(
            inspector.record(measuredWidth: 560, isVisible: true, currentStoredWidth: 280, containerWidth: 1000),
            "inspector: a repeated clamped frame must not cancel the scheduled commit"
        )
        expect(
            inspector.record(measuredWidth: 559.7, isVisible: true, currentStoredWidth: 280, containerWidth: 1000),
            "inspector: a sub-pixel final frame must not cancel the scheduled commit"
        )
        expectEqual(inspector.takeCommit(), 559.7, "inspector: releasing against the clamp still commits the final width")
    }

    TestRunner.add("shared width draft compares container-clamped widths for the inspector") {
        var draft = ColumnWidthDraft<InspectorColumnLayout>()

        expectEqual(
            draft.record(measuredWidth: 504, isVisible: true, currentStoredWidth: 560, containerWidth: 824),
            false,
            "a drag that cannot move the clamped column leaves the stored width untouched"
        )
        expectEqual(draft.hasPendingCommit, false)

        expect(
            draft.record(measuredWidth: 464, isVisible: true, currentStoredWidth: 560, containerWidth: 824),
            "a constrained drag commits the width it renders"
        )
        expect(
            draft.record(measuredWidth: 464, isVisible: true, currentStoredWidth: 560, containerWidth: 824),
            "the final frame of a constrained drag still commits the rendered width"
        )
        expectEqual(draft.takeCommit(), 464, "the constrained drag commits the rendered width")
    }

    // MARK: - Debouncer Timing and AppModel Integration

    TestRunner.add("shared width debouncer coalesces rapid frames for both layouts") {
        func exercise<Layout: ColumnWidthLayout>(
            _ layout: Layout.Type,
            name: String,
            current: Double,
            widths: [Double],
            containerWidth: CGFloat,
            expected: Double
        ) {
            var committed: [Double] = []
            MainActor.assumeIsolated {
                let debouncer = ColumnWidthDebouncer<Layout>(delay: .milliseconds(40))
                for width in widths {
                    debouncer.handleWidthChange(
                        measuredWidth: width,
                        isVisible: true,
                        currentStoredWidth: current,
                        containerWidth: containerWidth
                    ) { committed.append($0) }
                }
            }

            let start = Date()
            while Date().timeIntervalSince(start) < 0.015 {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            expectEqual(committed.isEmpty, true, "\(name): no commit occurs before the debounce interval elapses")

            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline && committed.isEmpty {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            expectEqual(committed.count, 1, "\(name): exactly one commit occurs")
            expectEqual(committed.first, expected, "\(name): the latest dragged width is committed")
        }

        exercise(
            SidebarLayout.self,
            name: "sidebar",
            current: 200,
            widths: [220, 240, 250],
            containerWidth: 0,
            expected: 250
        )
        exercise(
            InspectorColumnLayout.self,
            name: "inspector",
            current: 280,
            widths: [300, 330, 360],
            containerWidth: 0,
            expected: 360
        )
    }

    TestRunner.add("shared width debouncer cancels a pending commit when the column hides") {
        func exercise<Layout: ColumnWidthLayout>(
            _ layout: Layout.Type,
            name: String,
            current: Double,
            changed: Double
        ) {
            var committed: [Double] = []
            MainActor.assumeIsolated {
                let debouncer = ColumnWidthDebouncer<Layout>(delay: .milliseconds(40))
                debouncer.handleWidthChange(
                    measuredWidth: changed,
                    isVisible: true,
                    currentStoredWidth: current,
                    containerWidth: 0
                ) { committed.append($0) }
                debouncer.handleWidthChange(
                    measuredWidth: 0,
                    isVisible: false,
                    currentStoredWidth: current,
                    containerWidth: 0
                ) { committed.append($0) }
            }

            let deadline = Date().addingTimeInterval(0.3)
            while Date() < deadline && committed.isEmpty {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            expectEqual(committed.isEmpty, true, "\(name): hiding cancels the pending commit")
        }

        exercise(SidebarLayout.self, name: "sidebar", current: 200, changed: 260)
        exercise(InspectorColumnLayout.self, name: "inspector", current: 280, changed: 360)
    }

    TestRunner.add("shared width debouncer commits both column widths to AppModel and store") {
        do {
            let store = try ClipboardStore(inMemory: true)
            var sidebarCommitted = false
            var inspectorCommitted = false
            var appModel: AppModel?
            try MainActor.assumeIsolated {
                let history = ClipboardHistory(store: store)
                _ = try history.defaultTab()
                let model = AppModel(history: history)
                appModel = model
                model.bootstrap()

                expectEqual(model.preferences.sidebarWidth, 200, "sidebar: fresh model uses the default width")
                expectEqual(model.preferences.inspectorColumnWidth, 280, "inspector: fresh model uses the default width")

                let sidebar = ColumnWidthDebouncer<SidebarLayout>(delay: .milliseconds(30))
                sidebar.handleWidthChange(
                    measuredWidth: 250,
                    isVisible: true,
                    currentStoredWidth: model.preferences.sidebarWidth,
                    containerWidth: 0
                ) { newWidth in
                    model.updatePreferences { $0.sidebarWidth = newWidth }
                    sidebarCommitted = true
                }

                let inspector = ColumnWidthDebouncer<InspectorColumnLayout>(delay: .milliseconds(30))
                inspector.handleWidthChange(
                    measuredWidth: 350,
                    isVisible: true,
                    currentStoredWidth: model.preferences.inspectorColumnWidth,
                    containerWidth: 0
                ) { newWidth in
                    model.updatePreferences { $0.inspectorColumnWidth = newWidth }
                    inspectorCommitted = true
                }
            }

            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline && !(sidebarCommitted && inspectorCommitted) {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            MainActor.assumeIsolated {
                guard let model = appModel else {
                    TestRunner.fail("the model was not created")
                    return
                }
                expectEqual(sidebarCommitted, true, "sidebar: the debounced commit fired")
                expectEqual(inspectorCommitted, true, "inspector: the debounced commit fired")
                expectEqual(model.preferences.sidebarWidth, 250, "sidebar: preferences keep the committed width")
                expectEqual(model.preferences.inspectorColumnWidth, 350, "inspector: preferences keep the committed width")

                do {
                    let reloaded = try store.preferences()
                    expectEqual(reloaded.sidebarWidth, 250, "sidebar: the store persisted the committed width")
                    expectEqual(reloaded.inspectorColumnWidth, 350, "inspector: the store persisted the committed width")
                } catch {
                    TestRunner.fail("threw \(error)")
                }
            }
        } catch {
            TestRunner.fail("threw \(error)")
        }
    }
}

private func exerciseColumnWidthDraft<Layout: ColumnWidthLayout>(
    _ layout: Layout.Type,
    name: String,
    current: Double,
    changed: Double,
    belowMin: Double,
    aboveMax: Double,
    clampedAboveMax: Double,
    containerWidth: CGFloat
) {
    var draft = ColumnWidthDraft<Layout>()
    expectEqual(draft.hasPendingCommit, false, "\(name): fresh draft has nothing pending")

    expect(
        draft.record(
            measuredWidth: changed,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        ),
        "\(name): recording a valid changed width schedules a commit"
    )
    expectEqual(draft.hasPendingCommit, true, "\(name): the change is pending")
    expectEqual(draft.pendingValue, changed, "\(name): the pending value is the measured width")

    expectEqual(draft.takeCommit(), changed, "\(name): takeCommit returns the recorded width")
    expectEqual(draft.hasPendingCommit, false, "\(name): taking the commit clears pending")
    expectNil(draft.takeCommit(), "\(name): a second take returns nil")

    expectEqual(
        draft.record(
            measuredWidth: changed,
            isVisible: false,
            currentStoredWidth: current,
            containerWidth: containerWidth
        ),
        false,
        "\(name): a hidden measurement is rejected"
    )
    expectEqual(draft.hasPendingCommit, false, "\(name): rejecting clears pending")

    expectEqual(
        draft.record(
            measuredWidth: belowMin,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        ),
        false,
        "\(name): a width below the minimum is rejected"
    )
    expectEqual(draft.hasPendingCommit, false, "\(name): rejecting a sub-minimum width clears pending")

    expectEqual(
        draft.record(
            measuredWidth: current + 0.3,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        ),
        false,
        "\(name): sub-pixel noise schedules no write"
    )
    expectNil(draft.takeCommit())

    expectEqual(
        draft.record(
            measuredWidth: current - 0.3,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        ),
        false,
        "\(name): negative sub-pixel noise schedules no write"
    )
    expectNil(draft.takeCommit())

    expect(
        draft.record(
            measuredWidth: aboveMax,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        ),
        "\(name): an oversized drag schedules a write"
    )
    expectEqual(draft.takeCommit(), clampedAboveMax, "\(name): an oversized drag is clamped to the maximum")

    expect(
        draft.record(
            measuredWidth: current + 10,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        )
    )
    expect(
        draft.record(
            measuredWidth: current + 20,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        )
    )
    expect(
        draft.record(
            measuredWidth: current + 30,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        )
    )
    expectEqual(draft.takeCommit(), current + 30, "\(name): the latest dragged width wins")
    expectNil(draft.takeCommit())

    expect(
        draft.record(
            measuredWidth: current + 10,
            isVisible: true,
            currentStoredWidth: current,
            containerWidth: containerWidth
        )
    )
    draft.cancel()
    expectEqual(draft.hasPendingCommit, false, "\(name): cancel clears the pending commit")
    expectNil(draft.takeCommit())
}
