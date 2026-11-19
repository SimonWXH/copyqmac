// SPDX-License-Identifier: GPL-3.0-or-later
//
// SidebarTabRowLayoutTests.swift
//
// Headless layout tests for the sidebar tab rows: after any reorder (the
// .onMove drag path included) every row must fill the sidebar's column width,
// with the name truncating on the left and the count capsule pinned right.
//
// The drag itself needs the window server's physical mouse state, which a test
// cannot synthesize without taking over the desktop, so the suite drives the
// shipped reorder handler and, for the drag-specific leftover, injects the
// stale content-hugging width a completed drag leaves on the moved row's cell
// and asserts the sidebar does not keep it.

import AppKit
import Foundation
import SwiftUI

func registerSidebarTabRowLayoutTests() {
    TestRunner.currentSuite = "SidebarTabRowLayout"

    // MARK: - Rows fill the column at every allowed sidebar width

    TestRunner.add("tab rows fill the row width at the minimum, default, and maximum sidebar widths") {
        MainActor.assumeIsolated {
            do {
                for width in [SidebarLayout.minWidth, SidebarLayout.defaultWidth, SidebarLayout.maxWidth] {
                    let harness = try SidebarTabLayoutHarness(sidebarWidth: CGFloat(width))
                    expect(harness.allRowCellsFillColumn(), "at sidebar width \(width) every tab row must fill the row width")
                    expectEqual(harness.table?.bounds.width ?? 0, CGFloat(width), "the sidebar list must render at the requested width")
                    harness.close()
                }
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Reordering keeps rows full width

    TestRunner.add("reordering tabs through the shipped onMove handler keeps every row full width") {
        MainActor.assumeIsolated {
            do {
                let harness = try SidebarTabLayoutHarness(sidebarWidth: 200)
                defer { harness.close() }
                let movedTab = harness.model.tabs[0]

                harness.reorder(from: IndexSet(integer: 0), to: 3)

                expect(harness.allRowCellsFillColumn(), "after a reorder every tab row must still fill the row width")
                expectEqual(harness.model.tabs.map(\.id)[2], movedTab.id, "the reorder must move the first tab to index 2")
                expectEqual(harness.model.tabs.count, 4, "the reorder must not drop or duplicate a tab")
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - The drag leftover cannot survive a reorder

    TestRunner.add("a moved row left at a stale content-hugging width is replaced by a full-width row after the reorder") {
        MainActor.assumeIsolated {
            do {
                let harness = try SidebarTabLayoutHarness(sidebarWidth: 200)
                defer { harness.close() }
                let movedTab = harness.model.tabs[0]

                // What a completed drag leaves behind: the moved row's cell sized to
                // its content instead of the row. Inject that state on the row that is
                // about to move, then run the shipped reorder path.
                let staleCell = try harness.cellView(row: 0)
                let staleInstance = ObjectIdentifier(staleCell)
                harness.injectStaleContentWidth(cell: staleCell)

                harness.reorder(from: IndexSet(integer: 0), to: 3)

                expect(harness.allRowCellsFillColumn(), "a stale-width moved row must not survive the reorder; every row must fill the row width")

                // The mechanism: the reorder must replace the moved row's cell view
                // instead of reusing whatever the drag left behind.
                let movedRow = harness.model.tabs.firstIndex { $0.id == movedTab.id }
                expectNotNil(movedRow, "the moved tab must still be rendered")
                if let movedRow, let newCell = try? harness.cellView(row: movedRow) {
                    expect(ObjectIdentifier(newCell) != staleInstance, "the moved row's cell view must be recreated by the reorder, not reused from the drag")
                } else {
                    expect(false, "the moved row must still have a cell view")
                }
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Selection still works after the reorder

    TestRunner.add("selection still follows the moved tab after a reorder") {
        MainActor.assumeIsolated {
            do {
                let harness = try SidebarTabLayoutHarness(sidebarWidth: 200)
                defer { harness.close() }
                let movedTab = harness.model.tabs[0]
                harness.model.selectTab(movedTab.id)

                harness.reorder(from: IndexSet(integer: 0), to: 3)
                harness.settle(0.3)

                expectEqual(harness.model.selectedTabID, movedTab.id, "the model selection must still point at the moved tab")
                let movedRow = harness.model.tabs.firstIndex { $0.id == movedTab.id }
                expectNotNil(movedRow, "the moved tab must still be rendered")
                if let movedRow, let rowView = harness.rowView(atRow: movedRow) {
                    expect(rowView.isSelected, "the selected tab's row must stay selected after the reorder")
                }
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Row content fills whatever width the row offers

    TestRunner.add("the tab row content fills the offered width across sidebar row content widths") {
        MainActor.assumeIsolated {
            do {
                let harness = try SidebarTabLayoutHarness(sidebarWidth: 200)
                defer { harness.close() }

                // Content widths seen by a row across the allowed sidebar widths,
                // including one narrower than the row's ideal width.
                for offered in [CGFloat(90), 128, 168, 228] {
                    let width = harness.measureRowContentWidth(hostWidth: offered, tabName: "Beta")
                    expectNotNil(width, "the row content must render at width \(offered)")
                    if let width {
                        expectEqual(width, offered, accuracy: 0.5, "the row content must fill the offered width \(offered)")
                    }
                }
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }

    // MARK: - Rendered geometry: name left, capsule right, name truncates

    TestRunner.add("a rendered row keeps its name at the leading edge and its count capsule at the trailing edge as the width changes") {
        MainActor.assumeIsolated {
            do {
                let harness = try SidebarTabLayoutHarness(sidebarWidth: 200)
                defer { harness.close() }

                var margins: [CGFloat] = []
                for contentWidth in [CGFloat(128), 168, 228] {
                    guard let drawn = harness.renderedContentColumns(contentWidth: contentWidth, tabName: "A very long tab name that must truncate") else {
                        TestRunner.fail("the row must render at content width \(contentWidth)")
                        continue
                    }
                    expect(drawn.left <= 8, "the row must start at the leading edge (drawn from \(drawn.left) at width \(contentWidth))")
                    let margin = drawn.rightMargin
                    expect(margin <= 24, "the count capsule must end at the trailing edge (right margin \(margin) at width \(contentWidth))")
                    margins.append(margin)
                }
                if let first = margins.first {
                    for margin in margins {
                        expectEqual(margin, first, accuracy: 2, "the capsule must stay pinned to the trailing edge as the row width changes")
                    }
                }

                // A long name truncates instead of pushing the capsule inward.
                if let wide = harness.renderedContentColumns(contentWidth: 168, tabName: "A very long tab name that must truncate"),
                   let short = harness.renderedContentColumns(contentWidth: 168, tabName: "Be")
                {
                    expectEqual(wide.rightMargin, short.rightMargin, accuracy: 2, "a long tab name must not move the count capsule off the trailing edge")
                } else {
                    expect(false, "the row must render with both long and short names")
                }
            } catch {
                TestRunner.fail("threw \(error)")
            }
        }
    }
}

// MARK: - Harness

/// The shipped `SidebarTabView` in a real window over an in-memory store, so
/// the tests measure the same List, row, and reorder code the app ships.
@MainActor
private final class SidebarTabLayoutHarness {
    let model: AppModel
    let window: NSWindow
    private let hosting: NSHostingView<AnyView>

    init(sidebarWidth: CGFloat) throws {
        _ = NSApplication.shared
        let store = try ClipboardStore(inMemory: true)
        let history = ClipboardHistory(store: store)
        _ = try history.defaultTab()
        _ = try history.addTab(name: "Beta")
        _ = try history.addTab(name: "Gamma")
        _ = try history.addTab(name: "Delta")
        model = AppModel(history: history)
        model.bootstrap()

        hosting = NSHostingView(
            rootView: AnyView(
                SidebarTabView(model: model)
                    .frame(width: sidebarWidth)
            )
        )
        hosting.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: 420)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: sidebarWidth, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        settle(0.5)
    }

    var table: NSTableView? {
        Self.firstTableView(in: hosting)
    }

    func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
    }

    /// Runs the exact handler the shipped List attaches to `.onMove`.
    func reorder(from source: IndexSet, to destination: Int) {
        SidebarTabView(model: model).reorderTabs(from: source, to: destination)
        settle(0.5)
    }

    func rowView(atRow row: Int) -> NSTableRowView? {
        table?.rowView(atRow: row, makeIfNecessary: false)
    }

    /// The inset cell content view of a row, as opposed to the full-width
    /// separator drawing view that shares the row.
    func cellView(row: Int) throws -> NSView {
        let rowView = try unwrap(rowView(atRow: row) as NSView?, "row \(row) must have a row view")
        let cell = rowView.subviews.first { subview in
            subview.frame.origin.x > 1 && subview.frame.width > 10
        }
        return try unwrap(cell, "row \(row) must have an inset cell content view")
    }

    /// Shrinks a row's cell content view to a content-hugging width, the state
    /// a completed drag reorder leaves on the moved row.
    func injectStaleContentWidth(cell: NSView) {
        cell.frame = NSRect(x: cell.frame.origin.x, y: cell.frame.origin.y, width: 90, height: cell.frame.height)
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        settle(0.2)
    }

    /// Every rendered row's cell content view must fill its row view minus the
    /// sidebar's fixed horizontal insets (about 32 pt) with a little slack.
    func allRowCellsFillColumn() -> Bool {
        guard let table else { return false }
        guard table.numberOfRows > 0 else { return false }
        for row in 0..<table.numberOfRows {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { continue }
            guard let cell = rowView.subviews.first(where: { $0.frame.origin.x > 1 && $0.frame.width > 10 }) else {
                return false
            }
            if cell.frame.width < rowView.frame.width - 34 {
                return false
            }
        }
        return true
    }

    /// The width the shipped row content takes when a plain host view offers
    /// `hostWidth`, measured through a geometry preference.
    func measureRowContentWidth(hostWidth: CGFloat, tabName: String) -> CGFloat? {
        guard let tab = model.tabs.first(where: { $0.name == tabName }) else { return nil }
        final class Box {
            var width: CGFloat?
        }
        let box = Box()
        let row = SidebarTabRow(model: model, tab: tab)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { box.width = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in box.width = newWidth }
                }
            )
        let host = NSHostingView(rootView: AnyView(row.frame(width: hostWidth)))
        host.frame = NSRect(x: 0, y: 0, width: hostWidth, height: 60)
        host.layoutSubtreeIfNeeded()
        settle(0.2)
        return box.width
    }

    struct RenderedColumns {
        let left: CGFloat
        let rightMargin: CGFloat
    }

    /// Renders the shipped row with a real long tab name at `contentWidth` and
    /// reports the leftmost and rightmost columns that carry drawn pixels.
    /// Content alpha is used, so the measurement works in any appearance.
    func renderedContentColumns(contentWidth: CGFloat, tabName: String) -> RenderedColumns? {
        let store: ClipboardStore
        do { store = try ClipboardStore(inMemory: true) } catch { return nil }
        let history = ClipboardHistory(store: store)
        guard let tab = try? history.addTab(name: tabName) else { return nil }
        let renderModel = AppModel(history: history)
        renderModel.bootstrap()

        let height: CGFloat = 28
        let host = NSHostingView(rootView: AnyView(SidebarTabRow(model: renderModel, tab: tab).frame(width: contentWidth, height: height)))
        host.frame = NSRect(x: 0, y: 0, width: contentWidth, height: height)
        let window = NSWindow(
            contentRect: NSRect(x: 400, y: 500, width: contentWidth, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(0.4)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil
        guard let image = rep.cgImage else { return nil }

        let width = image.width
        let pixelHeight = image.height
        guard width > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: pixelHeight))
        guard let pointer = context.data?.bindMemory(to: UInt8.self, capacity: width * pixelHeight * 4) else {
            return nil
        }
        var leftMost = width
        var rightMost = -1
        for x in 0..<width {
            for y in 0..<pixelHeight where pointer[(y * width + x) * 4 + 3] > 10 {
                leftMost = min(leftMost, x)
                rightMost = max(rightMost, x)
                break
            }
        }
        guard rightMost >= 0 else { return nil }
        return RenderedColumns(left: CGFloat(leftMost), rightMargin: CGFloat(width - 1 - rightMost))
    }

    func close() {
        window.contentView = nil
    }

    private static func firstTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, !(table is EntryTableView) { return table }
        for subview in view.subviews {
            if let found = firstTableView(in: subview) { return found }
        }
        return nil
    }
}
