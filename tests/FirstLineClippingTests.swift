// The first line of Chinese text must clear the container that draws it.
//
// Two places clipped it: a list row that was measured while it still showed a
// placeholder kept that height when its two-line preview arrived, and the item
// editor laid its first line out with Helvetica's ascent, which is shorter than
// the CJK ink. Both fixes rest on numbers - the row-height tolerance and the
// editor's first-line headroom - so the numbers are asserted here rather than
// left to a hand test that only shows up on screen.

import AppKit
import Foundation
import SwiftUI

func registerFirstLineClippingTests() {
    let cjk = "我希望这个中文条目第一行完整可见"

    TestRunner.currentSuite = "row height"
    TestRunner.add("A row that grows past the tolerance is measured again") {
        // The placeholder a row shows while its presentation is built measures
        // 39 pt; the two-line CJK preview needs 55 pt. The cell clips the
        // difference, so the row has to be re-measured.
        expect(RowHeightPolicy.needsRemeasure(contentHeight: 55, rowHeight: 40))
        // An image row whose 34 pt thumbnail replaces the 28 pt fallback icon.
        expect(RowHeightPolicy.needsRemeasure(contentHeight: 42, rowHeight: 36))
    }

    TestRunner.add("A row whose content shrank is measured again") {
        // An edited entry that lost its second line should give the space back.
        expect(RowHeightPolicy.needsRemeasure(contentHeight: 40, rowHeight: 55))
    }

    TestRunner.add("AppKit's whole-point rounding alone does not trigger a measurement") {
        // AppKit keeps whole-point row heights, so a 39 pt content height can
        // legitimately live in a 40 pt row. Re-measuring that on every data
        // change would re-lay out the whole visible list for nothing.
        expect(!RowHeightPolicy.needsRemeasure(contentHeight: 39, rowHeight: 40))
        expect(!RowHeightPolicy.needsRemeasure(contentHeight: 40, rowHeight: 40))
        expect(!RowHeightPolicy.needsRemeasure(contentHeight: 55, rowHeight: 55))
    }

    TestRunner.currentSuite = "row height invalidation"
    TestRunner.add("A row model replaced off screen loses its cached height") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            let rows = (0..<30).map { clippingRow(id: Int64($0), text: "row \($0)") }
            let tableView = EntryTableView()
            tableView.headerView = nil
            let column = NSTableColumn(identifier: EntryListView.Coordinator.columnIdentifier)
            column.width = 240
            tableView.addTableColumn(column)
            tableView.usesAutomaticRowHeights = true
            tableView.rowHeight = 44
            tableView.intercellSpacing = .zero
            tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            tableView.frame = NSRect(x: 0, y: 0, width: 240, height: 80)

            let scrollView = NSScrollView()
            scrollView.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
            scrollView.documentView = tableView

            let coordinator = clippingListView(rows: rows, revision: 0, selection: selection)
                .makeCoordinator()
            coordinator.attach(to: tableView)
            tableView.dataSource = coordinator
            tableView.delegate = coordinator
            coordinator.applyRows()
            scrollView.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()

            expectEqual(tableView.numberOfRows, rows.count)
            let visible = tableView.rows(in: tableView.visibleRect)
            expect(visible.length > 0, "the table has to lay out its visible rows")
            let oldRect = tableView.rect(ofRow: 20)
            expect(
                !tableView.visibleRect.intersects(oldRect),
                "row 20 has to be outside the viewport for this test"
            )

            tableView.invalidatedRowHeights = IndexSet()
            var updated = rows
            updated[20] = clippingRow(
                id: 20,
                text: String(repeating: cjk, count: 2)
            )
            coordinator.parent = clippingListView(
                rows: updated,
                revision: 1,
                selection: selection
            )
            coordinator.applyRows()

            expect(
                tableView.invalidatedRowHeights.contains(20),
                "the replaced row kept the height AppKit measured for its old content"
            )
            expect(
                !tableView.invalidatedRowHeights.contains(0),
                "an unchanged row must not be measured again"
            )

            let cell = coordinator.tableView(tableView, viewFor: nil, row: 20)
            let requiredHeight = cell?.fittingSize.height ?? 0
            expect(
                requiredHeight > oldRect.height,
                "the two-line row has to need more height than the one-line row"
            )

            tableView.scrollRowToVisible(20)
            scrollView.layoutSubtreeIfNeeded()
            tableView.layoutSubtreeIfNeeded()
            let updatedRect = tableView.rect(ofRow: 20)
            expect(
                tableView.visibleRect.intersects(updatedRect),
                "the row has to be on screen for its height to be measured"
            )
            expectEqual(updatedRect.height, requiredHeight, accuracy: 1.5)
        }
    }

    TestRunner.add("A single-line Chinese preview wraps and unwraps with the column width") {
        MainActor.assumeIsolated {
            // To see this test fail, temporarily revert the width baked into
            // EntryRowContent (app/EntryListView.swift); the narrow row is then
            // measured at its ideal one-line width and the wrapped-height
            // assertion reports that the preview did not wrap.
            let selection = SelectionState()
            let row = clippingRow(id: 1, text: String(repeating: cjk, count: 2))
            let fixture = clippingTable(rows: [row], revision: 0, selection: selection, width: 240)
            let wrappedHeight = fixture.tableView.rect(ofRow: 0).height
            let wrappedContent = fixture.coordinator
                .tableView(fixture.tableView, viewFor: nil, row: 0)?
                .fittingSize.height ?? 0

            fixture.scrollView.frame = NSRect(x: 0, y: 0, width: 2000, height: 80)
            fixture.scrollView.layoutSubtreeIfNeeded()
            clippingDrainMainQueue()
            fixture.scrollView.layoutSubtreeIfNeeded()
            let oneLineHeight = fixture.tableView.rect(ofRow: 0).height
            let oneLineContent = fixture.coordinator
                .tableView(fixture.tableView, viewFor: nil, row: 0)?
                .fittingSize.height ?? 0

            let short = clippingTable(
                rows: [clippingRow(id: 2, text: "short")],
                revision: 0,
                selection: SelectionState(),
                width: 2000
            )
            let shortHeight = short.tableView.rect(ofRow: 0).height

            expect(wrappedContent > 0, "the narrow row has no measured content height")
            expectEqual(wrappedHeight, wrappedContent, accuracy: 1.5)
            expectEqual(oneLineHeight, oneLineContent, accuracy: 1.5)
            expectEqual(oneLineHeight, shortHeight, accuracy: 1.5)
            expect(
                wrappedHeight > oneLineHeight + RowHeightPolicy.tolerance,
                "the long single-line preview was measured as one line at its ideal width instead of wrapping at the column width"
            )
        }
    }

    TestRunner.add("An item list row draws in the configured display font") {
        MainActor.assumeIsolated {
            let row = clippingRow(id: 1, text: "Clipboard item")
            let bodyFixture = clippingTable(
                rows: [row],
                revision: 0,
                selection: SelectionState(),
                width: 400
            )
            let largeFont = NSFont.systemFont(ofSize: 28)
            let largeFixture = clippingTable(
                rows: [row],
                revision: 0,
                selection: SelectionState(),
                width: 400,
                font: largeFont
            )
            clippingDrainMainQueue()

            let bodyHeight = bodyFixture.tableView.rect(ofRow: 0).height
            let largeHeight = largeFixture.tableView.rect(ofRow: 0).height
            expect(
                largeHeight > bodyHeight + 1,
                "a 28 pt item list font has to draw taller than the body font (got \(largeHeight) pt vs \(bodyHeight) pt)"
            )
        }
    }

    TestRunner.add("A visible item list row follows a font change") {
        MainActor.assumeIsolated {
            let row = clippingRow(id: 1, text: "Clipboard item")
            let selection = SelectionState()
            let fixture = clippingTable(
                rows: [row],
                revision: 0,
                selection: selection,
                width: 400
            )
            clippingDrainMainQueue()
            let bodyHeight = fixture.tableView.rect(ofRow: 0).height

            fixture.coordinator.parent = clippingListView(
                rows: [row],
                revision: 0,
                selection: selection,
                font: NSFont.systemFont(ofSize: 28)
            )
            fixture.coordinator.applyRows()
            clippingDrainMainQueue()
            fixture.scrollView.layoutSubtreeIfNeeded()

            let largeHeight = fixture.tableView.rect(ofRow: 0).height
            expect(
                largeHeight > bodyHeight + 1,
                "an already visible row has to redraw and remeasure at the new font without a data change (got \(largeHeight) pt vs \(bodyHeight) pt)"
            )
        }
    }

    TestRunner.add("A visible row grows to the wrapped height of its preview") {
        MainActor.assumeIsolated {
            let selection = SelectionState()
            var rows = (0..<5).map { clippingRow(id: Int64($0), text: "row \($0)") }
            let fixture = clippingTable(rows: rows, revision: 0, selection: selection)
            let oldHeight = fixture.tableView.rect(ofRow: 0).height

            rows[0] = clippingRow(id: 0, text: String(repeating: cjk, count: 2))
            fixture.coordinator.parent = clippingListView(
                rows: rows,
                revision: 1,
                selection: selection
            )
            fixture.coordinator.applyRows()
            clippingDrainMainQueue()
            fixture.tableView.layoutSubtreeIfNeeded()

            let newHeight = fixture.tableView.rect(ofRow: 0).height
            expect(
                newHeight > oldHeight + RowHeightPolicy.tolerance,
                "the visible row kept its one-line height after its preview wrapped"
            )
        }
    }

    TestRunner.currentSuite = "first line clearance"
    TestRunner.add("The Edit Item editor keeps a Chinese first line clear of the clip") {
        let editor = PlainTextEditor.makeEditor(text: "\(cjk)\n第二行", delegate: nil)
        let scrollView = editor.scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        scrollView.layoutSubtreeIfNeeded()

        let textView = editor.textView
        let body = NSFont.preferredFont(forTextStyle: .body)
        expectEqual(textView.font?.fontName, body.fontName)
        expectEqual(textView.font?.pointSize, body.pointSize)
        expectEqual(
            textView.textContainerInset.height,
            PlainTextEditor.firstLineHeadroom,
            accuracy: 0.001
        )

        guard let firstInk = firstInkRow(in: textView) else {
            TestRunner.fail("the item text drew no ink")
            return
        }
        expect(
            firstInk >= 1,
            "the first line needs at least 1 pt of clear space, got \(firstInk) pt; raise PlainTextEditor.firstLineHeadroom"
        )
        // The chosen value, so a later "let's trim the padding" change has to
        // face this test and the measurement behind it.
        expectEqual(PlainTextEditor.firstLineHeadroom, 2)
    }

    TestRunner.add("The styled item editor keeps a Chinese first line clear of the clip") {
        // The styled editor hosts the same kind of view as the plain one, so it
        // needs the same headroom: a Chinese first line reaches higher than the
        // font's ascent and the clip view would cut off its top.
        let document = StyledTextDocument(runs: [
            StyledTextRun(text: "\(cjk)\n第二行", isBold: true, pointSize: 13),
        ])
        let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
        let scrollView = editor.scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        scrollView.layoutSubtreeIfNeeded()

        let textView = editor.textView
        expectEqual(textView.attributedString().string, document.plainText, "the editor shows the seeded text")
        expectEqual(
            textView.textContainerInset.height,
            PlainTextEditor.firstLineHeadroom,
            accuracy: 0.001,
            "the styled editor has to reserve the same first-line headroom"
        )

        guard let firstInk = firstInkRow(in: textView) else {
            TestRunner.fail("the styled item text drew no ink")
            return
        }
        expect(
            firstInk >= 1,
            "the styled editor's first line needs at least 1 pt of clear space, got \(firstInk) pt; raise PlainTextEditor.firstLineHeadroom"
        )
    }

    TestRunner.add("A short styled editor fills the clip it scrolls in") {
        let document = StyledTextDocument(runs: [StyledTextRun(text: "one line")])
        let editor = RichTextEditor.makeEditor(document: document, delegate: nil, format: .html)
        let scrollView = editor.scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        scrollView.layoutSubtreeIfNeeded()

        let clipSize = scrollView.contentView.bounds.size
        expect(clipSize.height > 0, "the scroll view has no clip height")
        expectEqual(editor.textView.minSize.height, clipSize.height, accuracy: 0.5)
        expect(
            editor.textView.frame.height >= clipSize.height - 0.5,
            "clicks below the text would land in the clip view, not the styled editor"
        )
    }

    TestRunner.add("The note editor keeps Helvetica 12 and clears the CJK clip") {
        let note = "\(cjk)\nLatin second line"
        let oldFont = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let editor = PlainTextEditor.makeEditor(
            text: note,
            delegate: nil,
            font: PlainTextEditor.noteFont
        )
        let scrollView = editor.scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        scrollView.layoutSubtreeIfNeeded()

        let textView = editor.textView
        expectEqual(textView.font?.fontName, oldFont.fontName)
        expectEqual(textView.font?.pointSize, oldFont.pointSize)
        expectEqual(
            textView.textContainerInset.height,
            PlainTextEditor.firstLineHeadroom,
            accuracy: 0.001
        )

        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else {
            TestRunner.fail("the note editor has no text layout")
            return
        }
        layoutManager.ensureLayout(for: container)
        let secondLineGlyph = layoutManager.glyphIndexForCharacter(
            at: (cjk as NSString).length + 1
        )
        let secondLine = layoutManager.lineFragmentRect(
            forGlyphAt: secondLineGlyph,
            effectiveRange: nil
        )
        expectEqual(
            secondLine.height,
            layoutManager.defaultLineHeight(for: oldFont),
            accuracy: 0.5,
            "the note editor kept its previous line height"
        )

        guard let firstInk = firstInkRow(in: textView) else {
            TestRunner.fail("the note drew no ink")
            return
        }
        expect(
            firstInk >= 1,
            "the note's first line needs at least 1 pt of clear space, got \(firstInk) pt"
        )
    }

    TestRunner.add("The old TextEditor configuration has less first-line clearance") {
        let oldFont = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let oldTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        oldTextView.font = oldFont
        oldTextView.isRichText = false
        oldTextView.drawsBackground = false
        oldTextView.textContainerInset = .zero
        oldTextView.isVerticallyResizable = true
        oldTextView.isHorizontallyResizable = false
        oldTextView.textContainer?.widthTracksTextView = true
        oldTextView.textContainer?.containerSize = NSSize(
            width: 240,
            height: CGFloat.greatestFiniteMagnitude
        )
        oldTextView.string = cjk

        let oldScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        oldScrollView.documentView = oldTextView
        oldScrollView.layoutSubtreeIfNeeded()

        let editor = PlainTextEditor.makeEditor(
            text: cjk,
            delegate: nil,
            font: PlainTextEditor.noteFont
        )
        let editorScrollView = editor.scrollView
        editorScrollView.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        editorScrollView.layoutSubtreeIfNeeded()

        guard let oldInk = firstInkRow(in: oldScrollView.contentView),
              let editorInk = firstInkRow(in: editorScrollView.contentView)
        else {
            TestRunner.fail("an editor first line drew no ink")
            return
        }
        expect(editorInk >= 1, "the editor's first line needs at least 1 pt of clearance")
        expect(
            oldInk < editorInk,
            "the old TextEditor configuration has to start nearer the clip than the editor"
        )
        expect(
            editorInk - oldInk >= PlainTextEditor.firstLineHeadroom - 0.5,
            "the editor's headroom has to add \(PlainTextEditor.firstLineHeadroom) pt of clearance"
        )
    }

    TestRunner.add("A short editor fills the clip it scrolls in") {
        let editor = PlainTextEditor.makeEditor(text: "one line", delegate: nil)
        let scrollView = editor.scrollView
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 220)
        scrollView.layoutSubtreeIfNeeded()

        let clipSize = scrollView.contentView.bounds.size
        expect(clipSize.height > 0, "the scroll view has no clip height")
        expectEqual(editor.textView.minSize.height, clipSize.height, accuracy: 0.5)
        expect(
            editor.textView.frame.height >= clipSize.height - 0.5,
            "clicks below the text would land in the clip view, not the editor"
        )
        expect(
            editor.textView.frame.width >= clipSize.width - 0.5,
            "the editor has to span the clip, not shrink to the text width"
        )
    }

    TestRunner.currentSuite = "note editing"
    TestRunner.add("The first note keystroke survives the stale update behind it") {
        MainActor.assumeIsolated {
            // The note pane reports each keystroke through a binding whose setter
            // drops the draft until the note-editing session exists, so the model
            // still holds the empty note when the update that follows the first
            // keystroke arrives. Writing that stale value back deleted the
            // character the user had just typed.
            var modelText = ""
            var editingWhenModelChanged: Bool?
            var coordinator: PlainTextEditor.Coordinator!
            let binding = Binding(
                get: { modelText },
                set: { value in
                    modelText = value
                    if editingWhenModelChanged == nil {
                        editingWhenModelChanged = coordinator?.isEditing
                    }
                }
            )
            coordinator = PlainTextEditor(text: binding, font: PlainTextEditor.noteFont)
                .makeCoordinator()
            coordinator.lastModelText = ""
            let editor = PlainTextEditor.makeEditor(
                text: "",
                delegate: coordinator,
                font: PlainTextEditor.noteFont
            )
            guard let window = makeEditorWindow(editor) else { return }
            let textView = editor.textView

            window.makeFirstResponder(textView)
            textView.insertText("我", replacementRange: textView.selectedRange())
            expectEqual(modelText, "我", "the first keystroke did not reach the model")
            expect(
                editingWhenModelChanged == true,
                "the editing session has to exist before the first keystroke reaches the model"
            )

            coordinator.applyModelText("", to: textView)
            expectEqual(textView.string, "我", "the first keystroke was erased by a stale model value")
            expectEqual(modelText, "我", "the model lost the value the first keystroke stored")
            window.makeFirstResponder(nil)
        }
    }

    TestRunner.add("A note change from the model is applied to the editor") {
        MainActor.assumeIsolated {
            // Switching entries has to replace the editor's text even though the
            // editor was just being edited: the model changed, so it wins.
            var modelText = ""
            let binding = Binding(get: { modelText }, set: { modelText = $0 })
            let coordinator = PlainTextEditor(text: binding, font: PlainTextEditor.noteFont)
                .makeCoordinator()
            coordinator.lastModelText = ""
            let editor = PlainTextEditor.makeEditor(
                text: "",
                delegate: coordinator,
                font: PlainTextEditor.noteFont
            )
            guard let window = makeEditorWindow(editor) else { return }
            let textView = editor.textView

            window.makeFirstResponder(textView)
            textView.insertText("甲", replacementRange: textView.selectedRange())
            coordinator.applyModelText("另一个条目的备注", to: textView)

            expectEqual(textView.string, "另一个条目的备注", "the model's change was ignored")
            expectEqual(coordinator.lastModelText, "另一个条目的备注")
            window.makeFirstResponder(nil)
        }
    }

    TestRunner.add("An editor that is not being edited shows the model text") {
        MainActor.assumeIsolated {
            // A blurred note box mirrors the model, so a draft the model rejected
            // cannot linger on screen once the user leaves the box.
            var modelText = ""
            let binding = Binding(get: { modelText }, set: { modelText = $0 })
            let coordinator = PlainTextEditor(text: binding, font: PlainTextEditor.noteFont)
                .makeCoordinator()
            coordinator.lastModelText = ""
            let editor = PlainTextEditor.makeEditor(
                text: "",
                delegate: coordinator,
                font: PlainTextEditor.noteFont
            )
            guard let window = makeEditorWindow(editor) else { return }
            let textView = editor.textView

            window.makeFirstResponder(textView)
            textView.insertText("没被保存的输入", replacementRange: textView.selectedRange())
            window.makeFirstResponder(nil)
            modelText = ""
            coordinator.applyModelText("", to: textView)

            expectEqual(textView.string, "", "a blurred editor has to show what the model holds")
        }
    }

    TestRunner.add("The text view's editing callbacks own the note editing session") {
        MainActor.assumeIsolated {
            // The note-editing session is what makes the model accept a draft, so
            // it has to exist before typing starts. The delegate's begin/end
            // callbacks are its only owner, and they run before the first
            // keystroke arrives.
            var focusedStates: [Bool] = []
            var isFocused = false
            let binding = Binding(get: { isFocused }, set: { isFocused = $0 })
            let coordinator = PlainTextEditor(
                text: .constant(""),
                font: PlainTextEditor.noteFont,
                isFocused: binding,
                onEditingChanged: { focusedStates.append($0) }
            ).makeCoordinator()
            let editor = PlainTextEditor.makeEditor(
                text: "",
                delegate: coordinator,
                font: PlainTextEditor.noteFont
            )
            guard let window = makeEditorWindow(editor) else { return }
            let textView = editor.textView

            window.makeFirstResponder(textView)
            expect(window.firstResponder === textView, "the editor has to take keyboard focus")

            textView.insertText("我", replacementRange: textView.selectedRange())
            textView.insertText("好", replacementRange: textView.selectedRange())
            expectEqual(focusedStates, [true], "the note session has to start with the first keystroke")
            expect(isFocused, "the focus the owner asked for has to follow the editor")
            expect(coordinator.isEditing, "the coordinator has to know the editor is editing")

            window.makeFirstResponder(nil)
            expectEqual(focusedStates, [true, false])
            expect(!isFocused, "losing focus has to release the owner's focus state")
            expect(!coordinator.isEditing, "the coordinator has to know editing ended")
        }
    }


}

@MainActor
private func clippingTable(
    rows: [EntryRow],
    revision: Int,
    selection: SelectionState,
    width: CGFloat = 240,
    font: NSFont? = nil
) -> (scrollView: NSScrollView, tableView: EntryTableView, coordinator: EntryListView.Coordinator) {
    let coordinator = clippingListView(
        rows: rows,
        revision: revision,
        selection: selection,
        font: font
    ).makeCoordinator()
    let tableView = EntryListView.makeTableView(coordinator: coordinator)
    tableView.tableColumns[0].width = width
    tableView.frame = NSRect(x: 0, y: 0, width: width, height: 80)

    let scrollView = NSScrollView()
    scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 80)
    scrollView.documentView = tableView
    coordinator.attach(to: tableView)
    coordinator.applyRows()
    scrollView.layoutSubtreeIfNeeded()
    tableView.layoutSubtreeIfNeeded()
    return (scrollView, tableView, coordinator)
}

@MainActor
private func makeEditorWindow(
    _ editor: (scrollView: PlainTextScrollView, textView: NSTextView)
) -> NSWindow? {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    editor.scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
    window.contentView = editor.scrollView
    window.layoutIfNeeded()
    guard window.contentView === editor.scrollView else {
        print("SKIP: could not create a window for the editor focus test")
        return nil
    }
    return window
}

private func firstInkRow(in view: NSView) -> CGFloat? {
    if let textView = view as? NSTextView, let container = textView.textContainer {
        textView.layoutManager?.ensureLayout(for: container)
    }
    let bounds = view.bounds
    guard bounds.width > 0, bounds.height > 0,
          let representation = view.bitmapImageRepForCachingDisplay(in: bounds)
    else { return nil }
    view.cacheDisplay(in: bounds, to: representation)
    guard let data = representation.bitmapData else { return nil }

    let scale = CGFloat(representation.pixelsWide) / bounds.width
    for row in 0..<representation.pixelsHigh {
        for column in 0..<representation.pixelsWide {
            let pixel = data.advanced(
                by: row * representation.bytesPerRow + column * representation.samplesPerPixel
            )
            let alpha = representation.samplesPerPixel > 3 ? pixel[3] : 255
            guard alpha > 200 else { continue }
            if pixel[0] < 150 || pixel[1] < 150 || pixel[2] < 150 {
                return CGFloat(row) / scale
            }
        }
    }
    return nil
}

@MainActor
private func clippingDrainMainQueue() {
    let deadline = Date().addingTimeInterval(0.05)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

private func clippingRow(id: Int64, text: String?) -> EntryRow {
    EntryRow(
        id: id,
        number: Int(id) + 1,
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
private func clippingListView(
    rows: [EntryRow],
    revision: Int,
    selection: SelectionState,
    font: NSFont? = nil
) -> EntryListView {
    EntryListView(
        rows: rows,
        rowsRevision: revision,
        selection: selection,
        font: font,
        singleClickActivates: false,
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
}
