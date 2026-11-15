// Tests for Layout B: split-ratio clamping, pane-height sums, minimum-height guard,
// pointer-to-ratio drag mapping, the shipped divider's drag events, the sidebar's
// tab counts, default reset, and windowLayout decode fallback.

import AppKit
import Foundation
import SwiftUI

func registerWindowLayoutTests() {
    TestRunner.currentSuite = "WindowLayout"

    // MARK: - Split Ratio Clamping

    TestRunner.add("split ratio below 0.20 collapses to 0.20") {
        expectEqual(InspectorSplitLayout.clampRatio(0.19), 0.20)
        expectEqual(InspectorSplitLayout.clampRatio(0.0), 0.20)
        expectEqual(InspectorSplitLayout.clampRatio(-0.5), 0.20)
    }

    TestRunner.add("split ratio above 0.80 collapses to 0.80") {
        expectEqual(InspectorSplitLayout.clampRatio(0.81), 0.80)
        expectEqual(InspectorSplitLayout.clampRatio(1.0), 0.80)
        expectEqual(InspectorSplitLayout.clampRatio(5.0), 0.80)
    }

    TestRunner.add("split ratio within 0.20...0.80 is preserved") {
        expectEqual(InspectorSplitLayout.clampRatio(0.20), 0.20)
        expectEqual(InspectorSplitLayout.clampRatio(0.55), 0.55)
        expectEqual(InspectorSplitLayout.clampRatio(0.80), 0.80)
        expectEqual(InspectorSplitLayout.clampRatio(0.42), 0.42)
    }

    // MARK: - Pane Heights Sum to Available Height

    TestRunner.add("two panes always sum exactly to the available height across ratios and sizes") {
        let testHeights: [CGFloat] = [60, 100, 120, 200, 350, 480, 600, 920, 1200]
        let testRatios: [Double] = [0.10, 0.20, 0.35, 0.50, 0.55, 0.65, 0.80, 0.95]

        for height in testHeights {
            for ratio in testRatios {
                let (preview, note) = InspectorSplitLayout.paneHeights(availableHeight: height, ratio: ratio)
                expectEqual(
                    preview + note,
                    height,
                    "preview (\(preview)) + note (\(note)) must equal availableHeight (\(height)) at ratio \(ratio)"
                )
            }
        }
    }

    // MARK: - Minimum-Height Guard

    TestRunner.add("minimum-height guard enforces at least 60pt per pane when height allows") {
        let totalHeight: CGFloat = 200
        // Ratio 0.20 would normally yield 40pt preview, but minimum guard forces preview >= 60pt
        let (previewLow, noteLow) = InspectorSplitLayout.paneHeights(availableHeight: totalHeight, ratio: 0.20)
        expect(previewLow >= InspectorSplitLayout.minPaneHeight, "preview height \(previewLow) must be >= 60")
        expect(noteLow >= InspectorSplitLayout.minPaneHeight, "note height \(noteLow) must be >= 60")
        expectEqual(previewLow + noteLow, totalHeight)

        // Ratio 0.80 would normally yield 40pt note, but minimum guard forces note >= 60pt
        let (previewHigh, noteHigh) = InspectorSplitLayout.paneHeights(availableHeight: totalHeight, ratio: 0.80)
        expect(previewHigh >= InspectorSplitLayout.minPaneHeight, "preview height \(previewHigh) must be >= 60")
        expect(noteHigh >= InspectorSplitLayout.minPaneHeight, "note height \(noteHigh) must be >= 60")
        expectEqual(previewHigh + noteHigh, totalHeight)
    }

    // MARK: - Default Reset

    TestRunner.add("double-click default reset value is 0.55") {
        expectEqual(InspectorSplitLayout.defaultRatio, 0.55)
        let defaultHeights = InspectorSplitLayout.paneHeights(availableHeight: 1000, ratio: InspectorSplitLayout.defaultRatio)
        expectEqual(defaultHeights.preview, 550)
        expectEqual(defaultHeights.note, 450)
    }

    // MARK: - Divider Drag Mapping

    TestRunner.add("pointer travel moves the split boundary by the same number of points") {
        let height: CGFloat = 300
        let startRatio = 0.55
        let start = InspectorSplitLayout.paneHeights(availableHeight: height, ratio: startRatio)
        var previousRatio = startRatio
        for step in 1...6 {
            previousRatio = InspectorSplitLayout.ratio(
                startRatio: startRatio,
                pointerDelta: CGFloat(step) * 10,
                availableHeight: height
            )
            let heights = InspectorSplitLayout.paneHeights(availableHeight: height, ratio: previousRatio)
            expectEqual(
                heights.preview,
                start.preview + CGFloat(step) * 10,
                "pointer travel of \(step * 10)pt must grow the preview by the same amount"
            )
        }
        let moved = InspectorSplitLayout.paneHeights(availableHeight: height, ratio: previousRatio)
        expectEqual(moved.preview, start.preview + 60)
        expectEqual(moved.note, start.note - 60, "the note pane shrinks by the same amount the preview grew")
        expectEqual(moved.preview + moved.note, height)
    }

    TestRunner.add("pointer travel above the divider start shrinks the preview one-for-one") {
        let height: CGFloat = 400
        let ratio = InspectorSplitLayout.ratio(startRatio: 0.5, pointerDelta: -40, availableHeight: height)
        expectEqual(ratio, 0.4, accuracy: 1e-9)
    }

    TestRunner.add("a dragged ratio is clamped to the allowed range") {
        expectEqual(InspectorSplitLayout.ratio(startRatio: 0.55, pointerDelta: 500, availableHeight: 300), 0.80)
        expectEqual(InspectorSplitLayout.ratio(startRatio: 0.55, pointerDelta: -500, availableHeight: 300), 0.20)
        expectEqual(InspectorSplitLayout.ratio(startRatio: 0.55, pointerDelta: 10, availableHeight: 0), 0.55)
    }

    TestRunner.add("a drag starts from the ratio the divider is drawn at") {
        let height: CGFloat = 280
        let storedRatio = 0.8
        let heights = InspectorSplitLayout.paneHeights(availableHeight: height, ratio: storedRatio)
        expectEqual(heights.preview, 220)
        expectEqual(heights.note, 60)

        let displayed = InspectorSplitLayout.displayedRatio(availableHeight: height, ratio: storedRatio)
        expectEqual(displayed, Double(heights.preview / height), accuracy: 1e-12)

        let dragged = InspectorSplitLayout.ratio(
            startRatio: displayed,
            pointerDelta: -2,
            availableHeight: height
        )
        let moved = InspectorSplitLayout.paneHeights(availableHeight: height, ratio: dragged)
        expectEqual(moved.preview, 218, "the boundary must follow the pointer from the first point")
        expectEqual(moved.note, 62)

        expectEqual(
            InspectorSplitLayout.displayedRatio(availableHeight: 300, ratio: 0.55),
            0.55,
            accuracy: 1e-12,
            "without the minimum-height guard the drawn ratio is the requested ratio"
        )
    }

    // MARK: - Divider Drag Events

    TestRunner.add("divider drag follows the pointer while the divider itself moves") {
        MainActor.assumeIsolated {
            let harness = DividerEventHarness()
            let divider = harness.divider
            var reported: [Double] = []
            var committed: [Double] = []
            divider.onRatioChange = { reported.append($0) }
            divider.onRatioCommit = { committed.append($0) }

            guard let down = harness.event(.leftMouseDown, windowY: 200) else {
                TestRunner.fail("could not create a mouse event")
                return
            }
            divider.mouseDown(with: down)
            for step in 1...6 {
                // The preview above the divider grows by 10pt on the same run
                // that reports the ratio, so the divider view itself travels
                // down with the pointer.
                divider.frame.origin.y = 200 - CGFloat(step) * 10
                guard let dragged = harness.event(.leftMouseDragged, windowY: 200 - CGFloat(step) * 10) else {
                    TestRunner.fail("could not create a mouse event")
                    return
                }
                divider.mouseDragged(with: dragged)
            }

            expectEqual(reported.count, 6, "every drag event reports the new ratio")
            expectEqual(
                reported.last ?? 0,
                0.55 + 60.0 / 400.0,
                accuracy: 1e-9,
                "60pt of pointer travel must move the boundary 60pt"
            )
            expect(committed.isEmpty, "a drag is not persisted before the pointer is released")

            if let up = harness.event(.leftMouseUp, windowY: 140) {
                divider.mouseUp(with: up)
            }
            expectEqual(committed, [reported.last ?? 0], "releasing the pointer commits the final ratio once")
            harness.close()
        }
    }

    TestRunner.add("double-clicking the divider resets it without committing a ratio") {
        MainActor.assumeIsolated {
            let harness = DividerEventHarness(ratio: 0.70)
            let divider = harness.divider
            var resets = 0
            var reported: [Double] = []
            var committed: [Double] = []
            divider.onReset = { resets += 1 }
            divider.onRatioChange = { reported.append($0) }
            divider.onRatioCommit = { committed.append($0) }

            guard let down = harness.event(.leftMouseDown, windowY: 200, clickCount: 2),
                  let up = harness.event(.leftMouseUp, windowY: 200, clickCount: 2)
            else {
                TestRunner.fail("could not create a mouse event")
                return
            }
            divider.mouseDown(with: down)
            divider.mouseUp(with: up)

            expectEqual(resets, 1, "a double-click asks for the default ratio")
            expect(reported.isEmpty, "a double-click does not start a drag")
            expect(committed.isEmpty, "a double-click does not commit a dragged ratio")
            harness.close()
        }
    }

    // MARK: - Shipped Layout B Window

    TestRunner.add("the shipped Layout B window renders the inspector split and resets on double click") {
        MainActor.assumeIsolated {
            do {
                let harness = try LayoutBWindowHarness(inspectorSplitRatio: 0.70)
                defer { harness.close() }

                guard let divider = harness.divider,
                      let previewPane = harness.previewPane,
                      let noteBox = harness.noteEditorBox
                else {
                    TestRunner.fail("Layout B did not render the inspector preview, divider, and note")
                    return
                }
                let column = previewPane.superview ?? previewPane
                let dividerFrame = divider.convert(divider.bounds, to: column)
                let heights = InspectorSplitLayout.paneHeights(
                    availableHeight: divider.availableHeight,
                    ratio: divider.currentRatio
                )

                expectEqual(Double(dividerFrame.height), 7, accuracy: 0.5, "the divider keeps its 7pt row")
                expectEqual(Double(previewPane.frame.width), 280, accuracy: 0.5, "the inspector column is 280pt wide")
                expect(divider.availableHeight > 100, "the split column has a real height")
                let drawnRatio = InspectorSplitLayout.displayedRatio(
                    availableHeight: divider.availableHeight,
                    ratio: 0.70
                )
                expectEqual(
                    divider.currentRatio,
                    drawnRatio,
                    accuracy: 1e-9,
                    "the divider is handed the ratio its boundary is drawn at, not the stored ratio"
                )
                expectEqual(
                    Double(previewPane.frame.height),
                    Double(heights.preview),
                    accuracy: 1.5,
                    "the preview pane takes the preview share of the column"
                )
                expectEqual(
                    Double(dividerFrame.minY),
                    Double(previewPane.frame.minY + heights.preview),
                    accuracy: 1.5,
                    "the divider starts where the preview pane ends"
                )

                let noteBottom = noteBox.frame.maxY + DesignTokens.Spacing.small
                expectEqual(
                    Double(noteBottom - dividerFrame.maxY),
                    Double(heights.note),
                    accuracy: 1.5,
                    "the note pane takes the note share of the column"
                )
                expectEqual(
                    Double(noteBottom - previewPane.frame.minY),
                    Double(divider.availableHeight + 7),
                    accuracy: 1.5,
                    "preview, divider, and note fill the split column"
                )
                expect(
                    previewPane.frame.minY > 80,
                    "the metadata block occupies the inspector above the split"
                )

                guard let click = harness.click(on: divider, clickCount: 2) else {
                    TestRunner.fail("could not create a mouse event")
                    return
                }
                divider.mouseDown(with: click.down)
                divider.mouseUp(with: click.up)
                expectEqual(
                    harness.model.preferences.inspectorSplitRatio,
                    InspectorSplitLayout.defaultRatio,
                    accuracy: 1e-9,
                    "double-clicking the shipped divider stores the default ratio"
                )

                harness.settle(0.2)
                if let redrawn = harness.divider {
                    expectEqual(
                        redrawn.currentRatio,
                        InspectorSplitLayout.displayedRatio(
                            availableHeight: redrawn.availableHeight,
                            ratio: InspectorSplitLayout.defaultRatio
                        ),
                        accuracy: 1e-12,
                        "the reset redraws the divider at the default split"
                    )
                }

                let selectedColumnHeight = divider.availableHeight
                harness.model.clearSelection()
                harness.settle(0.2)
                if let clearedDivider = harness.divider {
                    expect(
                        clearedDivider.availableHeight > selectedColumnHeight + 40,
                        "clearing the selection removes the metadata block and the split column grows into its space"
                    )
                }
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("a hosted column below the minimum height keeps the note pane at its minimum") {
        MainActor.assumeIsolated {
            do {
                let harness = try LayoutBWindowHarness(
                    inspectorSplitRatio: 0.80,
                    root: .layoutB,
                    size: NSSize(width: 900, height: 300)
                )
                defer { harness.close() }

                guard let divider = harness.divider,
                      let previewPane = harness.previewPane,
                      let noteBox = harness.noteEditorBox
                else {
                    TestRunner.fail("the short Layout B window did not render the inspector split")
                    return
                }
                let column = previewPane.superview ?? previewPane
                let dividerFrame = divider.convert(divider.bounds, to: column)
                let heights = InspectorSplitLayout.paneHeights(
                    availableHeight: divider.availableHeight,
                    ratio: divider.currentRatio
                )

                expect(
                    divider.availableHeight > 0 && divider.availableHeight <= 285,
                    "the hosted column is shorter than the minimum-height threshold"
                )
                expectEqual(
                    heights.note,
                    InspectorSplitLayout.minPaneHeight,
                    "the note pane keeps its minimum height"
                )
                expectEqual(
                    heights.preview,
                    divider.availableHeight - InspectorSplitLayout.minPaneHeight,
                    "the preview pane shrinks by the height the note pane keeps"
                )

                let drawn = InspectorSplitLayout.displayedRatio(
                    availableHeight: divider.availableHeight,
                    ratio: 0.80
                )
                expect(
                    abs(drawn - 0.80) > 0.01,
                    "the minimum height moves the drawn ratio away from the stored ratio"
                )
                expectEqual(
                    divider.currentRatio,
                    drawn,
                    accuracy: 1e-9,
                    "the divider is handed the ratio the minimum height produced"
                )
                expectEqual(
                    Double(previewPane.frame.height),
                    Double(heights.preview),
                    accuracy: 1.5,
                    "the preview pane takes the reduced preview height"
                )
                let noteBottom = noteBox.frame.maxY + DesignTokens.Spacing.small
                expectEqual(
                    Double(noteBottom - dividerFrame.maxY),
                    Double(heights.note),
                    accuracy: 1.5,
                    "the note pane keeps its minimum height on screen"
                )
                expectEqual(
                    Double(noteBottom - previewPane.frame.minY),
                    Double(divider.availableHeight + 7),
                    accuracy: 1.5,
                    "preview, divider, and note still fill the column"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Sidebar Keyboard

    TestRunner.add("the Layout B sidebar owns movement keys and Return while focused") {
        MainActor.assumeIsolated {
            do {
                let harness = try LayoutBWindowHarness()
                defer { harness.close() }

                harness.model.setFilterFocused(true)
                expectEqual(harness.model.keyboardFocus, .filter, "the filter claims the keyboard")
                harness.model.setListFocused(true)
                expectEqual(harness.model.keyboardFocus, .itemList, "the item list takes the keyboard over from the filter")
                harness.model.setListFocused(false)
                expectEqual(harness.model.keyboardFocus, .none, "losing the current focus clears the signal")

                let firstTab = harness.model.selectedTabID
                expect(harness.focusSidebar(), "the sidebar list can take keyboard focus")
                expectEqual(harness.model.keyboardFocus, .sidebar, "the model records the sidebar focus")
                expect(firstTab != harness.secondTab.id, "the second tab is a real target")

                let focus = harness.model.keyboardFocus
                expectEqual(
                    ListInteractionPolicy.handles(.down, noteEditing: false, searchEmpty: false, focus: focus),
                    false,
                    "the window leaves the arrow keys to the sidebar list"
                )
                for key in [ListKey.pageUp, .pageDown, .home, .end] {
                    expectEqual(
                        ListInteractionPolicy.handles(key, noteEditing: false, searchEmpty: false, focus: focus),
                        true,
                        "\(key) is routed to the sidebar selection"
                    )
                }
                expectEqual(
                    ListInteractionPolicy.handles(.enter, noteEditing: false, searchEmpty: false, focus: focus),
                    false,
                    "Return does not paste while the sidebar is focused"
                )
                expectEqual(
                    ListInteractionPolicy.handles(.delete, noteEditing: false, searchEmpty: true, focus: focus),
                    false,
                    "Backspace does not delete an item from the sidebar"
                )
                expectEqual(
                    ListInteractionPolicy.handles(.escape, noteEditing: false, searchEmpty: false, focus: focus),
                    true,
                    "Escape still reaches the window from the sidebar"
                )

                harness.model.setNoteEditing(true)
                expectEqual(
                    harness.model.handleSidebarNavigation(.home),
                    false,
                    "note editing keeps the page keys for the item list"
                )
                expectEqual(
                    harness.model.selectedTabID,
                    firstTab,
                    "note editing does not move the tab selection"
                )
                harness.model.setNoteEditing(false)

                expect(harness.sendKey(code: 119), "the window dispatches End to the sidebar")
                expectEqual(harness.model.selectedTabID, harness.secondTab.id, "End selects the last tab")
                expect(harness.sendKey(code: 115), "the window dispatches Home to the sidebar")
                expectEqual(harness.model.selectedTabID, firstTab, "Home selects the first tab")
                expect(harness.sendKey(code: 121), "the window dispatches Page Down to the sidebar")
                expectEqual(harness.model.selectedTabID, harness.secondTab.id, "Page Down selects the next page of tabs")
                expect(harness.sendKey(code: 116), "the window dispatches Page Up to the sidebar")
                expectEqual(harness.model.selectedTabID, firstTab, "Page Up selects the previous page of tabs")

                expect(harness.sendDownArrow(), "the window dispatches the arrow key")
                expectEqual(
                    harness.model.selectedTabID,
                    harness.secondTab.id,
                    "the arrow key moves the sidebar selection and the item list follows"
                )

                harness.model.setSidebarFocused(false)
                expectEqual(harness.model.keyboardFocus, .none, "leaving the sidebar clears the signal")
                expectEqual(
                    harness.model.handleSidebarNavigation(.home),
                    false,
                    "Home does not move tabs once the sidebar loses the keyboard"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("window hide and show preserves keyboard focus state without resync drift") {
        MainActor.assumeIsolated {
            do {
                let harness = try LayoutBWindowHarness()
                defer { harness.close() }

                harness.model.setSidebarFocused(true)
                expectEqual(harness.model.keyboardFocus, .sidebar)

                harness.model.windowDidHide()
                expectEqual(
                    harness.model.keyboardFocus,
                    .sidebar,
                    "hiding the window does not clear the keyboard focus signal"
                )

                harness.model.windowDidShow()
                expectEqual(
                    harness.model.keyboardFocus,
                    .sidebar,
                    "showing the window preserves the keyboard focus signal"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Sidebar Tab Counts

    TestRunner.add("one grouped query counts every tab's entries") {
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)
        expect(try store.entryCountsByTab().isEmpty, "a fresh store counts no tabs")

        let first = try history.defaultTab()
        let second = try history.addTab(name: "Second")
        for index in 1...2 {
            _ = try history.record([Fixtures.text("first \(index)")], into: first)
        }
        _ = try history.record([Fixtures.text("second")], into: second)

        let counts = try store.entryCountsByTab()
        expectEqual(counts[first.id], 2)
        expectEqual(counts[second.id], 1)
        expectEqual(counts.values.reduce(0, +), try store.count(), "the per-tab counts add up to the total")
    }

    TestRunner.add("sidebar counts every tab's stored entries, not the loaded window") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                let first = try history.defaultTab()
                let second = try history.addTab(name: "Second")
                for index in 1...3 {
                    guard case .inserted(let entry) = try history.record(
                        [Fixtures.text("first \(index)")],
                        into: first
                    ) else {
                        TestRunner.fail("the entry was not stored")
                        return
                    }
                    _ = try history.setPinned(entry.id, true)
                }
                _ = try history.record([Fixtures.text("second")], into: second)

                let model = AppModel(history: history)
                model.bootstrap()
                expectEqual(model.tabEntryCounts[first.id], 3)
                expectEqual(model.tabEntryCounts[second.id], 1)
                expectEqual(model.totalEntryCount, 4)

                model.updatePreferences { $0.defaultMaxItems = 2 }
                expectEqual(try store.count(tabID: first.id), 3, "pinned entries survive the trim")
                expectEqual(model.entries.count, 2, "the visible list is capped by the limit")
                expectEqual(model.tabEntryCounts[first.id], 3, "the badge keeps the stored total")
                expectEqual(model.tabEntryCounts[second.id], 1)

                _ = try history.record([Fixtures.text("another")], into: second)
                model.reload()
                expectEqual(model.tabEntryCounts[second.id], 2, "a capture refreshes the badge")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - WindowLayout Preferences and Decode Fallback

    TestRunner.add("windowLayout defaults to layoutB in preferences defaultValue") {
        let prefs = Preferences.defaultValue
        expectEqual(prefs.windowLayout, .layoutB)
        expectEqual(prefs.inspectorSplitRatio, 0.55)
    }

    TestRunner.add("windowLayout decode fallback for missing value resolves to layoutB") {
        let json = #"{"defaultMaxItems":250,"language":"en"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.windowLayout, .layoutB, "missing windowLayout must fall back to layoutB")
    }

    TestRunner.add("a legacy windowLayout field means no choice and resolves to layoutB") {
        let json = #"{"defaultMaxItems":250,"language":"en","windowLayout":"layoutA"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.windowLayout, .layoutB, "a pre-control windowLayout value must not be adopted as a choice")

        let encoded = try JSONEncoder().encode(decoded)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        expectEqual(object?["windowLayout"] as? String, "layoutA", "the legacy field is left untouched")
    }

    TestRunner.add("windowLayout decode fallback for unknown value resolves to layoutB") {
        let json = #"{"defaultMaxItems":250,"language":"en","windowLayoutChoice":"unknown_futuristic_layout"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.windowLayout, .layoutB, "unknown windowLayoutChoice string must fall back to layoutB")
    }

    TestRunner.add("a chosen windowLayout survives encode and decode under its own key") {
        let json = #"{"defaultMaxItems":250,"language":"en","windowLayoutChoice":"layoutA"}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        expectEqual(decoded.windowLayout, .layoutA, "the new key carries the choice")

        let encoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(Preferences.self, from: encoded)
        expectEqual(roundTripped.windowLayout, .layoutA)

        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        expectEqual(object?["windowLayoutChoice"] as? String, "layoutA")
        expect(object?["windowLayout"] == nil, "a blob with no legacy field does not gain one")
    }

    TestRunner.add("known windowLayout values survive encode and decode") {
        for layout in WindowLayout.allCases {
            var prefs = Preferences.defaultValue
            prefs.windowLayout = layout
            let encoded = try JSONEncoder().encode(prefs)
            let decoded = try JSONDecoder().decode(Preferences.self, from: encoded)
            expectEqual(decoded.windowLayout, layout)
        }
    }

    TestRunner.add("split ratio in preferences json is clamped on decode") {
        let jsonLow = #"{"inspectorSplitRatio":0.05}"#
        let decodedLow = try JSONDecoder().decode(Preferences.self, from: Data(jsonLow.utf8))
        expectEqual(decodedLow.inspectorSplitRatio, 0.20)

        let jsonHigh = #"{"inspectorSplitRatio":0.99}"#
        let decodedHigh = try JSONDecoder().decode(Preferences.self, from: Data(jsonHigh.utf8))
        expectEqual(decodedHigh.inspectorSplitRatio, 0.80)
    }

    TestRunner.add("windowLayout and inspectorSplitRatio survive store round-trip") {
        let store = try ClipboardStore(inMemory: true)
        var prefs = try store.preferences()
        expectEqual(prefs.windowLayout, .layoutB, "fresh store defaults to layoutB")

        prefs.windowLayout = .layoutA
        prefs.inspectorSplitRatio = 0.68
        try store.setPreferences(prefs)

        let reloaded = try store.preferences()
        expectEqual(reloaded.windowLayout, .layoutA)
        expectEqual(reloaded.inspectorSplitRatio, 0.68)

        prefs.windowLayout = .layoutB
        prefs.inspectorSplitRatio = 0.42
        try store.setPreferences(prefs)

        let reloadedB = try store.preferences()
        expectEqual(reloadedB.windowLayout, .layoutB)
        expectEqual(reloadedB.inspectorSplitRatio, 0.42)
    }

    TestRunner.add("settings layout control is localized in English and Simplified Chinese") {
        expectEqual(Localization.string(.settingsWindowLayoutLabel, language: .english), "Window layout")
        expectEqual(Localization.string(.settingsWindowLayoutTopTabs, language: .english), "Top tabs")
        expectEqual(Localization.string(.settingsWindowLayoutSidebarInspector, language: .english), "Sidebar + inspector")
        expectEqual(Localization.string(.settingsWindowLayoutLabel, language: .simplifiedChinese), "窗口布局")
        expectEqual(Localization.string(.settingsWindowLayoutTopTabs, language: .simplifiedChinese), "顶部标签页")
        expectEqual(Localization.string(.settingsWindowLayoutSidebarInspector, language: .simplifiedChinese), "侧边栏与检查器")
    }

    TestRunner.add("switching layouts at runtime preserves selection, current tab, and unfiltered list state") {
        MainActor.assumeIsolated {
            do {
                let store = try ClipboardStore(inMemory: true)
                let history = ClipboardHistory(store: store)
                _ = try history.defaultTab()
                let secondTab = try history.addTab(name: "Secondary")

                _ = try history.record([Fixtures.text("Tab 1 Item")])
                guard case .inserted(let entryA) = try history.record([Fixtures.text("Second Tab Alpha")], into: secondTab),
                      case .inserted(let entryB) = try history.record([Fixtures.text("Second Tab Beta")], into: secondTab),
                      case .inserted(let entryC) = try history.record([Fixtures.text("Second Tab Gamma")], into: secondTab)
                else {
                    TestRunner.fail("failed to insert test entries")
                    return
                }
                _ = entryA

                let model = AppModel(history: history)
                model.bootstrap()

                expectEqual(model.preferences.windowLayout, .layoutB, "initial layout defaults to layoutB")

                model.selectTab(secondTab.id)
                model.select(entryB.id)

                expectEqual(model.selectedTabID, secondTab.id)
                expectEqual(model.selectedEntryID, entryB.id)
                expectEqual(model.selectedEntryIDs, [entryB.id])
                expectEqual(model.searchText, "")
                let initialEntryIDs = model.entries.map(\.id)
                expectEqual(initialEntryIDs.count, 3)

                // Switch to Layout A
                model.updatePreferences { $0.windowLayout = .layoutA }
                expectEqual(model.preferences.windowLayout, .layoutA)
                expectEqual(model.selectedTabID, secondTab.id, "tab preserved when switching to layoutA")
                expectEqual(model.selectedEntryID, entryB.id, "selection preserved when switching to layoutA")
                expectEqual(model.selectedEntryIDs, [entryB.id], "selection list preserved when switching to layoutA")
                expectEqual(model.entries.map(\.id), initialEntryIDs, "unfiltered entries preserved when switching to layoutA")
                expectEqual(model.searchText, "", "unfiltered list state preserved when switching to layoutA")

                // Switch back to Layout B
                model.updatePreferences { $0.windowLayout = .layoutB }
                expectEqual(model.preferences.windowLayout, .layoutB)
                expectEqual(model.selectedTabID, secondTab.id, "tab preserved when switching back to layoutB")
                expectEqual(model.selectedEntryID, entryB.id, "selection preserved when switching back to layoutB")
                expectEqual(model.selectedEntryIDs, [entryB.id], "selection list preserved when switching back to layoutB")
                expectEqual(model.entries.map(\.id), initialEntryIDs, "unfiltered entries preserved when switching back to layoutB")
                expectEqual(model.searchText, "", "unfiltered list state preserved when switching back to layoutB")

                // Multi-selection preserved across switches
                model.selection.set(ids: [entryB.id, entryC.id], focus: entryC.id)
                expectEqual(model.selectedEntryIDs, [entryB.id, entryC.id])

                model.updatePreferences { $0.windowLayout = .layoutA }
                expectEqual(model.preferences.windowLayout, .layoutA)
                expectEqual(model.selectedEntryIDs, [entryB.id, entryC.id], "multi-selection preserved when switching to layoutA")
                expectEqual(model.selectedTabID, secondTab.id)

                model.updatePreferences { $0.windowLayout = .layoutB }
                expectEqual(model.preferences.windowLayout, .layoutB)
                expectEqual(model.selectedEntryIDs, [entryB.id, entryC.id], "multi-selection preserved when switching back to layoutB")
                expectEqual(model.selectedTabID, secondTab.id)
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("settings Window layout control writes the chosen layout through its binding") {
        MainActor.assumeIsolated {
            do {
                let harness = try SettingsLayoutPickerHarness()
                defer { harness.close() }

                expectEqual(
                    harness.segmentLabels,
                    ["Top tabs", "Sidebar + inspector"],
                    "the control is the Window layout picker"
                )
                expectEqual(harness.selectedSegment, 1, "the control starts on Layout B")
                expectEqual(harness.model.preferences.windowLayout, .layoutB)

                harness.selectSegment(0)
                expectEqual(harness.selectedSegment, 0)
                expectEqual(
                    harness.model.preferences.windowLayout,
                    .layoutA,
                    "clicking Top tabs stores layoutA"
                )

                harness.selectSegment(1)
                expectEqual(harness.selectedSegment, 1)
                expectEqual(
                    harness.model.preferences.windowLayout,
                    .layoutB,
                    "clicking Sidebar + inspector stores layoutB"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("hosted MainWindowView swaps the rendered arrangement across runtime layout switches") {
        MainActor.assumeIsolated {
            do {
                let harness = try LayoutBWindowHarness(root: .mainWindow)
                defer { harness.close() }

                expectEqual(harness.model.preferences.windowLayout, .layoutB, "the harness starts in layoutB")
                expect(harness.divider != nil, "Layout B renders the inspector split divider")
                expect(harness.sidebarTable != nil, "Layout B renders the tab sidebar")
                expect(harness.noteEditor != nil, "Layout B renders the note editor")

                harness.model.updatePreferences { $0.windowLayout = .layoutA }
                harness.settle(0.3)

                expectEqual(harness.model.preferences.windowLayout, .layoutA)
                expect(harness.divider == nil, "Layout A does not render the inspector split divider")
                expect(harness.sidebarTable == nil, "Layout A does not render the tab sidebar")
                expect(harness.noteEditor != nil, "Layout A still renders its bottom preview and note pane")

                harness.model.updatePreferences { $0.windowLayout = .layoutB }
                harness.settle(0.3)

                expectEqual(harness.model.preferences.windowLayout, .layoutB)
                expect(harness.divider != nil, "switching back to Layout B restores the inspector split divider")
                expect(harness.sidebarTable != nil, "switching back to Layout B restores the tab sidebar")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Sidebar Toggle Position and State Tests

    TestRunner.add("sidebar toggle button toggles columnVisibility between visible and hidden") {
        var visibility = NavigationSplitViewVisibility.all
        let binding = Binding(get: { visibility }, set: { visibility = $0 })
        let button = SidebarToggleButton(columnVisibility: binding, language: .english)

        expectEqual(button.isSidebarVisible, true, "sidebar starts visible")
        expectEqual(visibility, .all, "initial columnVisibility is .all")

        button.toggle()
        expectEqual(visibility, .detailOnly, "first toggle switches columnVisibility to .detailOnly (hidden)")
        expectEqual(button.isSidebarVisible, false, "button reflects hidden state")

        button.toggle()
        expectEqual(visibility, .all, "second toggle restores columnVisibility to .all (visible)")
        expectEqual(button.isSidebarVisible, true, "button reflects visible state")
    }

    TestRunner.add("sidebar toggle button renders identically across states") {
        MainActor.assumeIsolated {
            @MainActor
            func renderedPixels(for visibility: NavigationSplitViewVisibility) -> [UInt8]? {
                var value = visibility
                let binding = Binding(get: { value }, set: { value = $0 })
                let button = SidebarToggleButton(columnVisibility: binding, language: .english)
                let renderer = ImageRenderer(content: button)
                renderer.scale = 2
                guard let image = renderer.cgImage else { return nil }
                return pixelBytes(of: image)
            }

            guard let expanded = renderedPixels(for: .all),
                  let collapsed = renderedPixels(for: .detailOnly)
            else {
                TestRunner.fail("could not render the sidebar toggle button")
                return
            }
            expect(
                expanded.count == collapsed.count,
                "both states render the same number of pixels"
            )
            expect(
                !expanded.allSatisfy { $0 == 0 },
                "the render captures the actual button, not a blank image"
            )
            expect(
                expanded == collapsed,
                "the toggle button renders pixel-identically when the sidebar is expanded and collapsed"
            )
        }
    }

    TestRunner.add("sidebar toggle button sits right of the title and stays put across toggles") {
        MainActor.assumeIsolated {
            do {
                let harness = try LayoutBWindowHarness(root: .layoutB)
                defer { harness.close() }
                harness.settle(0.4)

                expect(!harness.isSidebarCollapsed, "the sidebar starts expanded")
                expectNil(
                    harness.automaticSidebarToggleItem,
                    "the automatic drifting sidebar toggle toolbar item is removed"
                )
                expectEqual(
                    harness.sidebarToggleToolbarItems.count,
                    1,
                    "exactly one sidebar toggle button is in the toolbar"
                )

                guard let expandedView = harness.sidebarToggleToolbarItems.first?.view else {
                    TestRunner.fail("could not find SidebarToggleButton toolbar item view")
                    return
                }
                let expandedFrame = expandedView.convert(expandedView.bounds, to: nil)
                expect(
                    expandedFrame.minX >= 240,
                    "toggle button sits right of the window title, got x=\(expandedFrame.minX)"
                )
                expectEqual(expandedFrame.width, 28, accuracy: 0.5, "toggle button width is 28pt")
                expectEqual(expandedFrame.height, 28, accuracy: 0.5, "toggle button height is 28pt")

                expect(harness.clickSidebarToggle(), "the toggle button receives the click")
                expect(harness.isSidebarCollapsed, "clicking the toggle collapses the sidebar")
                expectNil(
                    harness.automaticSidebarToggleItem,
                    "the automatic drifting sidebar toggle toolbar item stays removed when collapsed"
                )
                expectEqual(
                    harness.sidebarToggleToolbarItems.count,
                    1,
                    "exactly one sidebar toggle button is in the collapsed toolbar"
                )

                guard let collapsedView = harness.sidebarToggleToolbarItems.first?.view else {
                    TestRunner.fail("could not find SidebarToggleButton toolbar item view after collapsing")
                    return
                }
                let collapsedFrame = collapsedView.convert(collapsedView.bounds, to: nil)
                expectEqual(
                    collapsedFrame.origin.x,
                    expandedFrame.origin.x,
                    accuracy: 0.5,
                    "collapsing the sidebar does not move the toggle button horizontally"
                )
                expectEqual(
                    collapsedFrame.origin.y,
                    expandedFrame.origin.y,
                    accuracy: 0.5,
                    "collapsing the sidebar does not move the toggle button vertically"
                )
                expectEqual(
                    collapsedFrame.size,
                    expandedFrame.size,
                    "collapsing the sidebar does not resize the toggle button"
                )

                expect(harness.clickSidebarToggle(), "the toggle button receives the second click")
                expect(!harness.isSidebarCollapsed, "clicking the toggle expands the sidebar again")
                expectNil(
                    harness.automaticSidebarToggleItem,
                    "the automatic drifting sidebar toggle toolbar item stays removed when expanded again"
                )
                expectEqual(
                    harness.sidebarToggleToolbarItems.count,
                    1,
                    "exactly one sidebar toggle button is in the re-expanded toolbar"
                )

                guard let reexpandedView = harness.sidebarToggleToolbarItems.first?.view else {
                    TestRunner.fail("could not find SidebarToggleButton toolbar item view after expanding")
                    return
                }
                let reexpandedFrame = reexpandedView.convert(reexpandedView.bounds, to: nil)
                expectEqual(
                    reexpandedFrame.origin.x,
                    expandedFrame.origin.x,
                    accuracy: 0.5,
                    "expanding the sidebar does not move the toggle button horizontally"
                )
                expectEqual(
                    reexpandedFrame.origin.y,
                    expandedFrame.origin.y,
                    accuracy: 0.5,
                    "expanding the sidebar does not move the toggle button vertically"
                )
                expectEqual(
                    reexpandedFrame.size,
                    expandedFrame.size,
                    "expanding the sidebar does not resize the toggle button"
                )
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    TestRunner.add("sidebar toggle button Control-Command-S shortcut toggles the sidebar") {
        MainActor.assumeIsolated {
            let harness = SidebarToggleHarness()
            defer { harness.close() }

            expectEqual(harness.columnVisibility, .all, "the sidebar starts visible")

            expect(
                harness.performKeyEquivalent(),
                "the window routes ⌃⌘S to the sidebar toggle button"
            )
            expectEqual(harness.columnVisibility, .detailOnly, "⌃⌘S collapses the sidebar")

            expect(
                harness.performKeyEquivalent(),
                "the window routes ⌃⌘S to the sidebar toggle button again"
            )
            expectEqual(harness.columnVisibility, .all, "⌃⌘S expands the sidebar")
        }
    }
}

/// Normalizes a rendered image into a fixed-format RGBA byte buffer so two
/// renders can be compared pixel-for-pixel.
private func pixelBytes(of image: CGImage) -> [UInt8]? {
    let width = image.width
    let height = image.height
    guard width > 0, height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let pointer = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return nil }
    let buffer = UnsafeBufferPointer(start: pointer, count: width * height * 4)
    return [UInt8](buffer)
}

// MARK: - Divider event harness

/// The shipped divider view in an unshown window, so the drag and reset paths
/// the app installs are what the tests drive.
@MainActor
private final class DividerEventHarness {
    let window: NSWindow
    let divider: InspectorDividerNSView

    init(availableHeight: CGFloat = 400, ratio: Double = 0.55) {
        _ = NSApplication.shared
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
        window.contentView = container
        divider = InspectorDividerNSView(frame: NSRect(x: 0, y: 200, width: 280, height: 7))
        container.addSubview(divider)
        divider.availableHeight = availableHeight
        divider.currentRatio = ratio
    }

    func event(_ type: NSEvent.EventType, windowY: CGFloat, clickCount: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 140, y: windowY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )
    }

    func close() {
        window.contentView = nil
    }
}

// MARK: - Sidebar toggle button harness

/// The shipped `SidebarToggleButton` in an unshown window, so the test drives
/// the real button and its keyboard shortcut rather than a copy of them.
@MainActor
private final class SidebarToggleHarness {
    private final class Visibility {
        var columnVisibility = NavigationSplitViewVisibility.all
    }

    let window: NSWindow
    private let state: Visibility

    var columnVisibility: NavigationSplitViewVisibility { state.columnVisibility }

    init() {
        _ = NSApplication.shared
        let state = Visibility()
        self.state = state
        let hosting = NSHostingView(rootView: AnyView(SidebarToggleButton(
            columnVisibility: Binding(
                get: { state.columnVisibility },
                set: { state.columnVisibility = $0 }
            ),
            language: .english
        )))
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 60)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 60),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.pump()
        hosting.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func performKeyEquivalent() -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "s",
            charactersIgnoringModifiers: "s",
            isARepeat: false,
            keyCode: 1
        ) else { return false }
        let handled = window.performKeyEquivalent(with: event)
        Self.pump()
        return handled
    }

    func close() {
        window.contentView = nil
    }

    private static func pump() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
}

// MARK: - Layout B window harness

/// The shipped `MainWindowView` laid out in an unshown window with a stored
/// layout preference, so the deliverable renders through the real view tree.
/// The shipped Layout B view without the main window's minimum-size frame, so a
/// test can host it at a height where the split's minimum pane height applies.
private struct LayoutBRoot: View {
    @ObservedObject var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        LayoutBView(
            model: model,
            searchFocused: $searchFocused,
            onDismiss: {}
        )
    }
}

@MainActor
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

@MainActor
private final class LayoutBWindowHarness {
    enum Root {
        case mainWindow
        case layoutB
    }

    let model: AppModel
    let secondTab: ClipboardTab
    let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    private let keyMonitor = WindowKeyMonitor()

    init(
        inspectorSplitRatio: Double = 0.55,
        sidebarWidth: Double = SidebarLayout.defaultWidth,
        root: Root = .mainWindow,
        size: NSSize = NSSize(width: 900, height: 460)
    ) throws {
        _ = NSApplication.shared
        let store = try ClipboardStore(inMemory: true)
        var preferences = try store.preferences()
        preferences.windowLayout = .layoutB
        preferences.inspectorSplitRatio = inspectorSplitRatio
        preferences.sidebarWidth = sidebarWidth
        try store.setPreferences(preferences)
        let history = ClipboardHistory(store: store)
        secondTab = try history.addTab(name: "Later")
        let outcome = try history.record([Fixtures.text("layout b inspector sample")])
        let entry: ClipboardEntry
        switch outcome {
        case .inserted(let inserted): entry = inserted
        case .duplicate(let existing): entry = existing
        case .empty: throw UnwrapFailure()
        }

        model = AppModel(history: history)
        model.bootstrap()
        model.select(entry.id)
        switch root {
        case .mainWindow:
            hosting = NSHostingView(rootView: AnyView(MainWindowView(model: model, onDismiss: {})))
        case .layoutB:
            hosting = NSHostingView(rootView: AnyView(LayoutBRoot(model: model)))
        }
        hosting.frame = NSRect(origin: .zero, size: size)
        window = KeyableWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 1, height: 1)
        window.contentView = hosting
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        keyMonitor.start(
            window: window,
            searchActive: { [weak model] in !(model?.searchText.isEmpty ?? true) },
            noteEditing: { [weak model] in model?.isEditingNote ?? false },
            focus: { [weak model] in model?.keyboardFocus ?? .none },
            handler: { [weak model] key, flags in
                guard let model else { return false }
                return MainWindowController.handle(key: key, model: model, extending: flags.contains(.shift))
            }
        )
        settle(0.6)
    }

    func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
    }

    /// Every item in the window's toolbar, including the subitems of item
    /// groups, counted once each.
    var toolbarItems: [NSToolbarItem] {
        guard let toolbar = window.toolbar else { return [] }
        var seen = Set<ObjectIdentifier>()
        var items: [NSToolbarItem] = []
        func append(_ item: NSToolbarItem) {
            guard seen.insert(ObjectIdentifier(item)).inserted else { return }
            items.append(item)
            (item as? NSToolbarItemGroup)?.subitems.forEach(append)
        }
        toolbar.items.forEach(append)
        return items
    }

    var sidebarToggleToolbarItems: [NSToolbarItem] {
        toolbarItems.filter { $0.itemIdentifier.rawValue == "SidebarToggleButton" }
    }

    /// The automatic sidebar toggle SwiftUI inserts unless the view removes it.
    /// AppKit names its item `NSToolbarToggleSidebarItem`, while the item a
    /// `NavigationSplitView` inserts carries a framework-scoped identifier that
    /// still ends in `toggleSidebar`, so match both spellings case-insensitively.
    var automaticSidebarToggleItem: NSToolbarItem? {
        toolbarItems.first {
            $0.itemIdentifier.rawValue.range(of: "toggleSidebar", options: .caseInsensitive) != nil
        }
    }

    var divider: InspectorDividerNSView? { Self.firstDivider(in: hosting) }

    var noteEditor: NSTextView? { Self.firstEditableTextView(in: hosting) }

    var sidebarTable: NSTableView? { Self.firstTableView(in: hosting) }

    /// Whether the split item that hosts the sidebar is collapsed. The split
    /// item reports the `NavigationSplitView` state directly, while
    /// `NSSplitView.isSubviewCollapsed` stays false until the collapse animation
    /// completes, which an unshown window never does.
    var isSidebarCollapsed: Bool {
        guard let contentView = window.contentView,
              let splitView = Self.firstSplitView(in: contentView),
              let controller = Self.splitViewController(for: splitView),
              let sidebar = controller.splitViewItems.first
        else { return false }
        return sidebar.isCollapsed
    }

    @discardableResult
    func clickSidebarToggle() -> Bool {
        guard let view = sidebarToggleToolbarItems.first?.view,
              let events = click(on: view)
        else { return false }
        window.sendEvent(events.down)
        window.sendEvent(events.up)
        settle(0.3)
        return true
    }

    @discardableResult
    func clickSidebarRow(at row: Int = 0) -> Bool {
        guard let table = sidebarTable, row < table.numberOfRows else {
            return false
        }
        let rowRect = table.rect(ofRow: row)
        let midPoint = NSPoint(x: rowRect.midX, y: rowRect.midY)
        let windowPoint = table.convert(midPoint, to: nil)
        guard let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ), let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return false }
        NSApp.postEvent(up, atStart: false)
        table.mouseDown(with: down)
        settle(0.2)
        return model.keyboardFocus == .sidebar
    }

    @discardableResult
    func focusSidebar() -> Bool {
        clickSidebarRow(at: 0)
    }

    @discardableResult
    func sendKey(code: Int, characters: String = "") -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(code)
        ) else { return false }
        NSApp.sendEvent(event)
        settle(0.2)
        return true
    }

    func sendDownArrow() -> Bool {
        sendKey(code: 125, characters: "\u{F701}")
    }

    /// The preview pane: the 280pt sibling of the divider that ends where the
    /// divider begins.
    var previewPane: NSView? {
        guard let dividerView = divider,
              let column = dividerView.superview?.superview
        else { return nil }
        let dividerFrame = dividerView.convert(dividerView.bounds, to: column)
        return column.subviews.first { candidate in
            abs(candidate.frame.width - 280) < 0.5
                && abs(candidate.frame.maxY - dividerFrame.minY) < 0.5
                && candidate.frame.height > 0
        }
    }

    /// The glass box around the note editor, inset from the note pane by one
    /// `Spacing.small` margin on every side.
    var noteEditorBox: NSView? {
        let inset = DesignTokens.Spacing.small
        guard let editor = noteEditor else { return nil }
        var view: NSView = editor
        while let parent = view.superview {
            if abs(view.frame.width - (280 - 2 * inset)) < 0.5, parent.frame.width > 280 {
                return view
            }
            view = parent
        }
        return nil
    }

    func click(on view: NSView, clickCount: Int = 1) -> (down: NSEvent, up: NSEvent)? {
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: 1
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return nil }
        return (down, up)
    }

    func close() {
        keyMonitor.stop()
        window.contentView = nil
    }

    private static func firstDivider(in view: NSView) -> InspectorDividerNSView? {
        if let divider = view as? InspectorDividerNSView { return divider }
        for subview in view.subviews {
            if let found = firstDivider(in: subview) { return found }
        }
        return nil
    }

    private static func splitViewController(for view: NSView) -> NSSplitViewController? {
        var responder: NSResponder? = view
        while let current = responder {
            if let controller = current as? NSSplitViewController { return controller }
            responder = current.nextResponder
        }
        return nil
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        if let splitView = view as? NSSplitView { return splitView }
        for subview in view.subviews {
            if let found = firstSplitView(in: subview) { return found }
        }
        return nil
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, !(table is EntryTableView) { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }

    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.isEditable, !textView.isFieldEditor {
            return textView
        }
        for subview in view.subviews {
            if let found = firstEditableTextView(in: subview) { return found }
        }
        return nil
    }
}

// MARK: - Settings layout picker harness

/// The real preferences window content in an unshown window, so the Window
/// layout segmented control the app ships is what the test clicks.
@MainActor
private final class SettingsLayoutPickerHarness {
    let model: AppModel
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>
    private let control: NSSegmentedControl

    init() throws {
        _ = NSApplication.shared
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)
        _ = try history.defaultTab()
        let model = AppModel(history: history)
        model.bootstrap()
        self.model = model

        hosting = NSHostingView(
            rootView: AnyView(PreferencesView(model: model, fontFamilies: FontFamilyCatalog()))
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 470)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 470),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        Self.pump(0.6)
        hosting.layoutSubtreeIfNeeded()

        guard let control = Self.layoutControl(in: hosting) else { throw UnwrapFailure() }
        self.control = control
    }

    var segmentLabels: [String] {
        (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
    }

    var selectedSegment: Int { control.selectedSegment }

    func selectSegment(_ index: Int) {
        control.setSelected(true, forSegment: index)
        if let action = control.action {
            NSApp.sendAction(action, to: control.target, from: control)
        }
        pump(0.2)
    }

    func close() {
        window.contentView = nil
    }

    private func pump(_ seconds: TimeInterval) {
        Self.pump(seconds)
    }

    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func layoutControl(in view: NSView) -> NSSegmentedControl? {
        let layoutLabels = [
            Localization.string(.settingsWindowLayoutTopTabs, language: .english),
            Localization.string(.settingsWindowLayoutSidebarInspector, language: .english)
        ]
        if let segmented = view as? NSSegmentedControl {
            let labels = (0..<segmented.segmentCount).map { segmented.label(forSegment: $0) }
            if labels == layoutLabels { return segmented }
        }
        for subview in view.subviews {
            if let found = layoutControl(in: subview) { return found }
        }
        return nil
    }
}
