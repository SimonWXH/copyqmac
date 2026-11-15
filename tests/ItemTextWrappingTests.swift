// SPDX-License-Identifier: GPL-3.0-or-later
//
// ItemTextWrappingTests.swift
//
// Headless tests for Layout B item list primary text auto-wrapping,
// line-limit cap (3 lines max), smooth row height adaptation,
// light/dark appearance consistency, and single-line secondary metadata.

import AppKit
import Foundation
import SwiftUI

func registerItemTextWrappingTests() {
    TestRunner.currentSuite = "ItemTextWrapping"

    let sampleText1Line = "Short clip"
    let sampleText2Lines = "This entry wraps across two lines in this column."
    let sampleText3Lines = "This is a longer entry that takes three full lines of text in this column to display all content."
    let sampleText5Lines = "This is an extremely long clipboard entry with extensive text that easily spans five or six lines when rendered in a narrow column, designed to verify that the primary text strictly caps at three lines and does not grow unboundedly, ending in an ellipsis tail truncation."

    TestRunner.add("Primary text wrapping row height scales across 1, 2, and 3 lines in Layout B") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            let row1 = wrappingRow(id: 1, text: sampleText1Line)
            let row2 = wrappingRow(id: 2, text: sampleText2Lines)
            let row3 = wrappingRow(id: 3, text: sampleText3Lines)

            let fixture = wrappingTable(rows: [row1, row2, row3], width: 280, maxTextLines: 3, selection: selection)
            wrappingDrainMainQueue()
            fixture.tableView.layoutSubtreeIfNeeded()

            let h1 = fixture.tableView.rect(ofRow: 0).height
            let h2 = fixture.tableView.rect(ofRow: 1).height
            let h3 = fixture.tableView.rect(ofRow: 2).height

            expect(
                h2 > h1 + RowHeightPolicy.tolerance,
                "2-line row height (\(h2)) must be greater than 1-line row height (\(h1))"
            )
            expect(
                h3 > h2 + RowHeightPolicy.tolerance,
                "3-line row height (\(h3)) must be greater than 2-line row height (\(h2))"
            )
        }
    }

    TestRunner.add("Primary text strictly caps at 3 lines in Layout B even for very long text") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            let row3 = wrappingRow(id: 1, text: sampleText3Lines)
            let row5 = wrappingRow(id: 2, text: sampleText5Lines)

            let fixture = wrappingTable(rows: [row3, row5], width: 280, maxTextLines: 3, selection: selection)
            wrappingDrainMainQueue()
            fixture.tableView.layoutSubtreeIfNeeded()

            let h3 = fixture.tableView.rect(ofRow: 0).height
            let h5 = fixture.tableView.rect(ofRow: 1).height

            // A 5-line text must be capped at 3 lines, so its row height matches the 3-line row within tolerance
            expectEqual(
                h5, h3, accuracy: 2.0,
                "text exceeding 3 lines must cap at the 3-line row height (\(h3) vs \(h5))"
            )
        }
    }

    TestRunner.add("Layout A preserves 2-line cap while Layout B allows 3-line wrapping") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            let rowLong = wrappingRow(id: 1, text: sampleText3Lines)

            // Layout A: maxTextLines = 2
            let fixtureA = wrappingTable(rows: [rowLong], width: 280, maxTextLines: 2, selection: selection)
            wrappingDrainMainQueue()
            fixtureA.tableView.layoutSubtreeIfNeeded()
            let heightLayoutA = fixtureA.tableView.rect(ofRow: 0).height

            // Layout B: maxTextLines = 3
            let fixtureB = wrappingTable(rows: [rowLong], width: 280, maxTextLines: 3, selection: selection)
            wrappingDrainMainQueue()
            fixtureB.tableView.layoutSubtreeIfNeeded()
            let heightLayoutB = fixtureB.tableView.rect(ofRow: 0).height

            expect(
                heightLayoutB > heightLayoutA + RowHeightPolicy.tolerance,
                "Layout B 3-line row height (\(heightLayoutB)) must exceed Layout A 2-line row height (\(heightLayoutA))"
            )
        }
    }

    TestRunner.add("Row height adapts smoothly when column width is narrowed and widened") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            let row = wrappingRow(id: 1, text: sampleText3Lines)

            // Start at a wide column (800 pt) where text fits in 1 or 2 lines
            let fixture = wrappingTable(rows: [row], width: 800, maxTextLines: 3, selection: selection)
            wrappingDrainMainQueue()
            fixture.tableView.layoutSubtreeIfNeeded()
            let wideHeight = fixture.tableView.rect(ofRow: 0).height

            // Narrow column to 260 pt: text wraps to 3 lines, row height expands
            fixture.tableView.tableColumns[0].width = 260
            fixture.scrollView.frame = NSRect(x: 0, y: 0, width: 260, height: 200)
            fixture.tableView.setFrameSize(NSSize(width: 260, height: 200))
            wrappingDrainMainQueue()
            fixture.tableView.layoutSubtreeIfNeeded()
            let narrowHeight = fixture.tableView.rect(ofRow: 0).height

            expect(
                narrowHeight > wideHeight + RowHeightPolicy.tolerance,
                "narrowing the column must increase row height due to text wrapping (narrow=\(narrowHeight) vs wide=\(wideHeight))"
            )

            // Widen column back to 800 pt: text unwraps, row height contracts back
            fixture.tableView.tableColumns[0].width = 800
            fixture.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
            fixture.tableView.setFrameSize(NSSize(width: 800, height: 200))
            wrappingDrainMainQueue()
            fixture.tableView.layoutSubtreeIfNeeded()
            let reWidenedHeight = fixture.tableView.rect(ofRow: 0).height

            expectEqual(
                reWidenedHeight, wideHeight, accuracy: 2.0,
                "widening the column must restore the compact row height (reWidened=\(reWidenedHeight) vs initial=\(wideHeight))"
            )
        }
    }

    TestRunner.add("Item wrapping behavior and height calculations are identical in light and dark mode") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            let row = wrappingRow(id: 1, text: sampleText3Lines)

            // Aqua (Light)
            let lightFixture = wrappingTable(rows: [row], width: 280, maxTextLines: 3, selection: selection)
            lightFixture.scrollView.appearance = NSAppearance(named: .aqua)
            wrappingDrainMainQueue()
            lightFixture.tableView.layoutSubtreeIfNeeded()
            let lightHeight = lightFixture.tableView.rect(ofRow: 0).height

            // DarkAqua (Dark)
            let darkFixture = wrappingTable(rows: [row], width: 280, maxTextLines: 3, selection: selection)
            darkFixture.scrollView.appearance = NSAppearance(named: .darkAqua)
            wrappingDrainMainQueue()
            darkFixture.tableView.layoutSubtreeIfNeeded()
            let darkHeight = darkFixture.tableView.rect(ofRow: 0).height

            expectEqual(
                darkHeight, lightHeight, accuracy: 1.0,
                "wrapping row height in dark appearance (\(darkHeight)) must match light appearance (\(lightHeight))"
            )
        }
    }

    TestRunner.add("Secondary metadata line stays single-line and does not wrap") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            // Even in a very narrow width (180 pt) with note badge, secondary metadata line stays 1 line
            let row = EntryRow(
                id: 1,
                number: 1,
                kind: .text,
                primaryText: "Short",
                richText: nil,
                fileNames: [],
                fileCount: 0,
                relativeTime: "12 hours ago",
                pinned: true,
                hasNote: true,
                icon: nil
            )

            let fixture = wrappingTable(rows: [row], width: 180, maxTextLines: 3, selection: selection)
            wrappingDrainMainQueue()
            fixture.tableView.layoutSubtreeIfNeeded()

            let height = fixture.tableView.rect(ofRow: 0).height
            // A 1-line text with single-line secondary metadata has compact height (~44 pt)
            expect(
                height <= 48,
                "row with short primary text must keep compact height even with metadata in narrow column (got \(height))"
            )
        }
    }
}

// MARK: - Test Helpers

@MainActor
private func wrappingTable(
    rows: [EntryRow],
    width: CGFloat = 280,
    maxTextLines: Int = 3,
    selection: SelectionState
) -> (scrollView: NSScrollView, tableView: EntryTableView, coordinator: EntryListView.Coordinator) {
    let listView = EntryListView(
        rows: rows,
        rowsRevision: 0,
        selection: selection,
        font: nil,
        singleClickActivates: false,
        language: .english,
        maxTextLines: maxTextLines,
        actions: .none,
        contextActions: .none,
        onSelectionChange: { _ in },
        onActivate: { _ in },
        onCopy: { _ in },
        onFocusChange: { _ in },
        onRowBecameVisible: { _ in },
        banner: nil,
        onBannerAction: {},
        onBannerDismiss: {}
    )

    let coordinator = listView.makeCoordinator()
    let tableView = EntryListView.makeTableView(coordinator: coordinator)
    tableView.tableColumns[0].width = width
    tableView.frame = NSRect(x: 0, y: 0, width: width, height: 200)

    let scrollView = NSScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 200)
    scrollView.documentView = tableView
    coordinator.attach(to: tableView)
    coordinator.applyRows()
    scrollView.layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()
    return (scrollView, tableView, coordinator)
}

private func wrappingRow(id: Int64, text: String) -> EntryRow {
    EntryRow(
        id: id,
        number: Int(id),
        kind: .text,
        primaryText: text,
        richText: nil,
        fileNames: [],
        fileCount: 0,
        relativeTime: "now",
        pinned: false,
        hasNote: false,
        icon: nil
    )
}

@MainActor
private func wrappingDrainMainQueue() {
    let deadline = Date().addingTimeInterval(0.06)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}
