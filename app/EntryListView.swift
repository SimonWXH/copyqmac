// The clipboard list, backed by an `NSTableView`.
//
// Why AppKit instead of `List`: on macOS a SwiftUI `List` is data-driven. Any
// change that invalidates the view that owns it - including a selection change
// - makes SwiftUI rebuild the `ForEach` row values and run the list diff over
// every entry before the native table applies the selection. At a thousand
// entries that is milliseconds of main-thread work per click and per arrow key,
// which is exactly the stutter this list had. A view-based `NSTableView` only
// asks its data source for the rows that are on screen, reuses cell views
// through `makeView(withIdentifier:owner:)`, and moves selection with
// `selectRowIndexes(_:byExtendingSelection:)`, which touches no data at all.
//
// The bridge keeps it that way:
// * `rows` is precomputed by `AppModel` and rebuilt only when the entries
//   change, never when the selection changes.
// * Selection is a separate `SelectionState` object; this view subscribes to it
//   directly, so no SwiftUI view body re-evaluates for a selection change.
// * Each realized row hosts a small SwiftUI view for the identical visual
//   design. Only the ~20 on-screen cells exist, and only the cell whose data
//   changed is reconfigured.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The pasteboard type a row drag publishes. The tab strip accepts it and then
/// asks the model to move the current selection; the payload itself only has to
/// prove the drag came from this list.
enum EntryDrag {
    static let identifier = "com.copyqmac.entry-ids"
    static let pasteboardType = NSPasteboard.PasteboardType(identifier)
    static let contentType = UTType(exportedAs: identifier)
}

/// One selection the native table made with the mouse.
struct ListSelectionChange {
    /// The row under the pointer, which is what the modifier commands act on.
    let clickedID: Int64?
    /// What the table reports it selected, used only when there is no clicked
    /// row (for example a deselection while the pointer is elsewhere).
    let ids: Set<Int64>
    let focus: Int64?
    /// Shift was held, so the range has to be extended from the anchor.
    let extending: Bool
    /// Command was held, so one row has to be toggled.
    let command: Bool
}

// MARK: - Row model

/// Everything a row draws, already decoded and formatted.
///
/// Building one is a cache lookup, never decoding or a store read, and the
/// array is stable across selection changes.
struct EntryRow: Identifiable, Equatable {
    let id: Int64
    let number: Int
    /// Nil until the background presentation for this entry is ready.
    let kind: ClipboardContentKind?
    let primaryText: String?
    /// Styled content for an HTML or RTF entry, already parsed and cached.
    /// Nil for text-only entries, which keep the plain `primaryText` path.
    let richText: AttributedString?
    let fileNames: [String]
    let fileCount: Int
    let relativeTime: String
    let pinned: Bool
    let hasNote: Bool
    let icon: NSImage?

    static let placeholder = EntryRow(
        id: -1,
        number: 0,
        kind: nil,
        primaryText: nil,
        richText: nil,
        fileNames: [],
        fileCount: 0,
        relativeTime: "",
        pinned: false,
        hasNote: false,
        icon: nil
    )
}

/// Which rows lost the height AppKit remembered for them.
///
/// AppKit only drops a row's cached height when the whole table is reloaded or
/// when the row is named here, so every row whose model changed has to be named,
/// whether or not it is on screen when the change arrives. A row that was
/// measured while it still showed a placeholder would otherwise keep that height
/// when its two-line preview arrives off screen, and draw clipped when scrolled
/// back in.
enum RowHeightInvalidation {
    static func changedRows(from previous: [EntryRow], to current: [EntryRow]) -> IndexSet {
        guard previous.count == current.count else {
            return IndexSet(integersIn: 0..<current.count)
        }
        var changed = IndexSet()
        for index in current.indices where previous[index] != current[index] {
            changed.insert(index)
        }
        return changed
    }
}

/// The row actions a row can invoke. Kept as closures so the row view does not
/// observe (and therefore re-evaluate with) the whole app model.
struct EntryRowActions {
    var togglePin: (Int64) -> Void
    var remove: (Int64) -> Void
    var thumbnail: (Int64) -> NSImage?
    var entry: (Int64) -> ClipboardEntry?

    init(
        togglePin: @escaping (Int64) -> Void = { _ in },
        remove: @escaping (Int64) -> Void = { _ in },
        thumbnail: @escaping (Int64) -> NSImage? = { _ in nil },
        entry: @escaping (Int64) -> ClipboardEntry? = { _ in nil }
    ) {
        self.togglePin = togglePin
        self.remove = remove
        self.thumbnail = thumbnail
        self.entry = entry
    }

    static let none = EntryRowActions()
}

/// Commands the row context menu offers beyond the row-specific ones.
///
/// New Item and Edit Item call the same model entry points as the Item menu,
/// and the availability closure is the rule that menu validates against, so a
/// right click cannot offer an action the menu bar would disable.
struct EntryContextActions {
    var newItem: () -> Void
    var editItem: (Int64) -> Void
    var editItemAvailability: (Int64) -> EditItemAvailability
    var canCreateNewItem: () -> Bool
    /// Removes the whole selection. The row context menu uses this so a right
    /// click inside a multi-selection deletes what is highlighted, not just the
    /// row under the pointer.
    var removeSelection: () -> Void

    static let none = EntryContextActions(
        newItem: {},
        editItem: { _ in },
        editItemAvailability: { _ in
            EditItemAvailability(isEnabled: false, title: EditItemAvailability.defaultTitle())
        },
        canCreateNewItem: { false },
        removeSelection: {}
    )
}

// MARK: - Row metrics

/// Metrics governing row presentation and line limits in entry lists.
enum EntryRowMetrics {
    /// Default line limit for Layout A and compact single-column views.
    static let defaultMaxTextLines = 2
    /// Expanded line limit for Layout B resizable item list column.
    static let expandedMaxTextLines = 6
}

// MARK: - Row content

private struct EntryRowContent: View {
    let row: EntryRow
    let actions: EntryRowActions
    let language: AppLanguage
    /// The width the row is drawn in.
    ///
    /// SwiftUI measures an `NSHostingView`'s ideal size at the content's own
    /// ideal width, where a long text fits on one line, so a row that wraps was
    /// measured as a one-line row and the cell clipped the second line - and,
    /// because the row centers its content, the first line's top with it. Baking
    /// the row's real width into the content makes the measured height the height
    /// the text actually needs, which is also what lets the table keep the row
    /// height in step with the content.
    let width: CGFloat
    /// The font the item text draws in, from the History ▸ Fonts preference.
    /// Nil keeps the row's default body font.
    let font: NSFont?
    /// Maximum lines for primary text wrapping before truncating with an ellipsis.
    var maxTextLines: Int = EntryRowMetrics.defaultMaxTextLines

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.card) {
            // Verbatim: grouped digits ("1,000") wrap in a 28pt gutter.
            Text(verbatim: "\(row.number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 28, alignment: .trailing)

            leadingPreview

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxSmall) {
                primaryText.font(font.map(Font.init))
                HStack(spacing: DesignTokens.Spacing.small) {
                    Text(row.relativeTime)
                        .font(DesignTokens.Typography.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(kindLabel)
                        .font(DesignTokens.Typography.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    if row.hasNote {
                        Label(
                            Localization.string(.rowNoteBadge, language: language),
                            systemImage: "note.text"
                        )
                            .font(DesignTokens.Typography.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Spacing.xSmall)

            if isHovering {
                HoverActionButton(
                    systemImage: row.pinned ? "pin.slash" : "pin",
                    help: Localization.string(
                        row.pinned ? .menuItemUnpin : .menuItemPin,
                        language: language
                    )
                ) {
                    actions.togglePin(row.id)
                }
                HoverActionButton(
                    systemImage: "trash",
                    help: Localization.string(.rowDeleteHelp, language: language)
                ) {
                    actions.remove(row.id)
                }
            } else if row.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.Colors.notice)
                    .help(Localization.string(.rowPinnedHelp, language: language))
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xSmall)
        .frame(width: width > 0 ? width : nil, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var kindLabel: String {
        guard let kind = row.kind else { return "" }
        return Localization.contentKindLabel(kind, language: language)
    }

    @ViewBuilder
    private var leadingPreview: some View {
        switch row.kind {
        case .image:
            if let thumbnail = actions.thumbnail(row.id) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
            } else {
                fallbackIcon("photo")
            }
        case .files:
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                fallbackIcon("doc")
            }
        case .html, .rtf:
            fallbackIcon("doc.richtext")
        case .text, .other:
            fallbackIcon("doc.text")
        case nil:
            fallbackIcon("doc.text")
        }
    }

    private func fallbackIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous).fill(.quaternary)
            )
    }

    @ViewBuilder
    private var primaryText: some View {
        if let kind = row.kind {
            if kind == .files {
                fileNames
            } else if kind == .html || kind == .rtf, let richText = row.richText {
                // The stored HTML/RTF, drawn with its fonts and colours. The
                // compact rendition keeps headings inside the fixed row height,
                // and the line limit clips anything longer than maxTextLines.
                Text(richText)
                    .lineLimit(maxTextLines)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let text = row.primaryText, !text.isEmpty {
                Text(text)
                    .lineLimit(maxTextLines)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(Localization.string(.rowNoPreview, language: language))
                    .foregroundStyle(.secondary)
            }
        } else {
            // The presentation is being built off the main thread; keep the
            // row's height without doing any work here.
            Text(" ")
        }
    }

    /// The names of the copied files, at most two of them.
    @ViewBuilder
    private var fileNames: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.hairline) {
            ForEach(Array(row.fileNames.prefix(2).enumerated()), id: \.offset) { _, name in
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            if row.fileCount > 2 {
                Text(Localization.format(.rowMoreFiles, language: language, row.fileCount - 2))
                    .font(DesignTokens.Typography.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Native list

/// A view-based table view that renders one SwiftUI row per realized cell and
/// moves selection in AppKit, without rebuilding the data.
struct EntryListView: NSViewRepresentable {
    let rows: [EntryRow]
    let rowsRevision: Int
    let selection: SelectionState
    /// The item list display font from the preferences, or nil for the body
    /// font the list drew with before the preference existed.
    var font: NSFont? = nil
    /// Whether a single click activates the clicked row instead of only
    /// selecting it. Comes from the History ▸ Activation preference.
    let singleClickActivates: Bool
    /// The interface language, used by the row help and the context menu.
    var language: AppLanguage = .english
    /// Maximum lines for primary text wrapping.
    var maxTextLines: Int = EntryRowMetrics.defaultMaxTextLines
    let actions: EntryRowActions
    let contextActions: EntryContextActions
    /// Reports the complete selection the user made with the mouse. The focus
    /// is the last clicked row, or the previously focused one when AppKit did
    /// not report a click (a keyboard-driven change).
    let onSelectionChange: (ListSelectionChange) -> Void
    let onActivate: (Int64) -> Void
    let onCopy: (Int64) -> Void
    let onFocusChange: (Bool) -> Void
    let onRowBecameVisible: (Int64) -> Void
    /// The transient message to show over the top of the list, or nil.
    let banner: NoticeBannerContent?
    let onBannerAction: () -> Void
    let onBannerDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    static func makeTableView(coordinator: Coordinator) -> EntryTableView {
        let tableView = EntryTableView()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.headerView = nil
        tableView.addTableColumn(NSTableColumn(identifier: Coordinator.columnIdentifier))
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = true
        tableView.rowHeight = 44
        tableView.intercellSpacing = .zero
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = true
        tableView.focusRingType = .none
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        // Rows also drag onto the tab strip. The selection, not the row under
        // the pointer, is what moves, so the drag source only needs to prove
        // it came from this list.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.target = coordinator
        tableView.action = #selector(Coordinator.handleSingleClick(_:))
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        tableView.contextMenuProvider = { [weak coordinator] row in
            coordinator?.contextMenu(for: row)
        }
        tableView.emptyAreaMenuProvider = { [weak coordinator] in
            coordinator?.emptyAreaContextMenu()
        }
        tableView.focusChangeHandler = { [weak coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        tableView.widthChangeHandler = { [weak coordinator] in
            coordinator?.listWidthChanged()
        }
        return tableView
    }

    func makeNSView(context: Context) -> EntryListScrollView {
        let tableView = Self.makeTableView(coordinator: context.coordinator)
        let scrollView = EntryListScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.keepBannerOnTop()
        scrollView.configureBanner(banner, onAction: onBannerAction, onDismiss: onBannerDismiss)

        context.coordinator.attach(to: tableView)
        return scrollView
    }

    func updateNSView(_ scrollView: EntryListScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyRows()
        scrollView.configureBanner(banner, onAction: onBannerAction, onDismiss: onBannerDismiss)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("CopyQmacEntryColumn")
        static let cellIdentifier = NSUserInterfaceItemIdentifier("CopyQmacEntryCell")

        var parent: EntryListView
        private weak var tableView: EntryTableView?
        private var rowIDs: [Int64] = []
        private var lastRows: [EntryRow] = []
        private var appliedRowsRevision = -1
        private var appliedLanguage: AppLanguage?
        /// The font the realized cells were configured with, so a preference
        /// change reaches rows that are already on screen.
        private var appliedFont: NSFont?
        private var appliedMaxTextLines: Int?
        private var cancellables: [Any] = []
        /// Set while a deferred re-measure of the visible rows is pending.
        private var isRemeasureScheduled = false
        /// Set while a deferred redraw at a new width is pending.
        private var isWidthRefreshScheduled = false
        /// Set while the list itself is being updated, so AppKit's selection
        /// notification is not mistaken for a user selection.
        private var isApplyingSelection = false
        private var clickActivationPolicy = ClickActivationPolicy()

        init(parent: EntryListView) {
            self.parent = parent
        }

        deinit {
            for observer in cancellables.compactMap({ $0 as? NSObjectProtocol }) {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(to tableView: EntryTableView) {
            self.tableView = tableView
            cancellables = [
                parent.selection.$snapshot.sink { [weak self] snapshot in
                    guard let self, let tableView = self.tableView else { return }
                    self.applySelection(snapshot, in: tableView)
                },
                parent.selection.$revealRequest.sink { [weak self] _ in
                    guard let self, let tableView = self.tableView,
                          let focus = parent.selection.focusedEntryID,
                          let row = parent.rows.firstIndex(where: { $0.id == focus })
                    else { return }
                    tableView.scrollRowToVisible(row)
                    self.notifyVisibleRows()
                },
            ]
            if let clipView = tableView.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                cancellables.append(
                    NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification,
                        object: clipView,
                        queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.notifyVisibleRows() }
                    }
                )
            }
        }

        /// Asks the model to prepare the rows the user can see. Off-screen rows
        /// keep their placeholder and cost nothing until they scroll in.
        private func notifyVisibleRows() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.lowerBound..<visible.upperBound {
                guard parent.rows.indices.contains(row) else { continue }
                parent.onRowBecameVisible(parent.rows[row].id)
            }
        }

        /// Reconfigures the table after the row models changed.
        ///
        /// Rebuilding the rows is a data event (capture, delete, filter); a
        /// selection change never gets here.
        func applyRows() {
            guard let tableView else { return }
            let newIDs = parent.rows.map(\.id)
            let languageChanged = parent.language != appliedLanguage
            appliedLanguage = parent.language
            let fontChanged = appliedFont != parent.font
            appliedFont = parent.font
            let maxTextLinesChanged = appliedMaxTextLines != parent.maxTextLines
            appliedMaxTextLines = parent.maxTextLines
            if newIDs == rowIDs {
                var needsRefresh = false
                if parent.rowsRevision != appliedRowsRevision {
                    appliedRowsRevision = parent.rowsRevision
                    let changed = RowHeightInvalidation.changedRows(from: lastRows, to: parent.rows)
                    lastRows = parent.rows
                    invalidateRowHeights(changed, in: tableView)
                    needsRefresh = true
                }
                if fontChanged || maxTextLinesChanged {
                    invalidateRowHeights(IndexSet(integersIn: 0..<tableView.numberOfRows), in: tableView)
                    needsRefresh = true
                }
                if needsRefresh {
                    refreshVisibleRows(in: tableView)
                    notifyVisibleRows()
                } else if languageChanged {
                    refreshVisibleRows(in: tableView)
                }
                return
            }
            rowIDs = newIDs
            lastRows = parent.rows
            appliedRowsRevision = parent.rowsRevision
            isApplyingSelection = true
            tableView.reloadData()
            isApplyingSelection = false
            applySelection(parent.selection.snapshot, in: tableView)
            notifyVisibleRows()
        }

        /// Reconfigures the visible cells after the row models changed.
        ///
        /// Configuring a cell replaces the SwiftUI row inside it, which can
        /// change how tall the row needs to be: a row that was still drawing the
        /// placeholder when AppKit measured it now draws two lines, or an image
        /// row's thumbnail arrived. AppKit keeps the height it measured for a
        /// row, so without asking it to measure the row again the cell would clip
        /// the taller content - and the row centers its content vertically, which
        /// clips the first line's top. `RowHeightPolicy` owns the decision.
        private func refreshVisibleRows(in tableView: NSTableView) {
            configureVisibleRows(in: tableView)
            scheduleRemeasure(ofVisibleRowsIn: tableView)
        }

        /// Hands the visible cells their current row model at the current width.
        private func configureVisibleRows(in tableView: NSTableView) {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            let width = Self.contentWidth(in: tableView)
            for row in visible.lowerBound..<visible.upperBound {
                guard parent.rows.indices.contains(row),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? EntryCellView
                else { continue }
                cell.configure(
                    row: parent.rows[row],
                    actions: parent.actions,
                    language: parent.language,
                    width: width,
                    font: parent.font,
                    maxTextLines: parent.maxTextLines
                )
            }
        }

        /// Asks AppKit to measure the visible rows again, once the reconfigured
        /// cells have taken effect.
        ///
        /// Setting a hosting view's root view takes effect on SwiftUI's next
        /// update pass, so a cell fitted in the same turn still reports the old
        /// content's height. Measuring after the turn gives the height the row
        /// actually needs, which is what AppKit then stores for it.
        private func scheduleRemeasure(ofVisibleRowsIn tableView: NSTableView) {
            guard !isRemeasureScheduled else { return }
            isRemeasureScheduled = true
            DispatchQueue.main.async { [weak self, weak tableView] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isRemeasureScheduled = false
                    guard let tableView else { return }
                    self.remeasureVisibleRows(in: tableView)
                }
            }
        }

        private func remeasureVisibleRows(in tableView: NSTableView) {
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            var rowsNeedingMeasurement = IndexSet()
            for row in visible.lowerBound..<visible.upperBound {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? EntryCellView
                else { continue }
                if RowHeightPolicy.needsRemeasure(
                    contentHeight: cell.preferredHeight,
                    rowHeight: tableView.rect(ofRow: row).height
                ) {
                    rowsNeedingMeasurement.insert(row)
                }
            }
            if !rowsNeedingMeasurement.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: rowsNeedingMeasurement)
            }
        }

        /// The width a row's content is drawn in: the column the table draws.
        private static func contentWidth(in tableView: NSTableView) -> CGFloat {
            let columnWidth = tableView.rect(ofColumn: 0).width
            return columnWidth > 0 ? columnWidth : tableView.bounds.width
        }

        /// The list changed width, so every row draws at a new width and may
        /// wrap differently. Reconfiguring changes the SwiftUI hierarchy, so it
        /// waits for the next turn instead of running inside the table's own
        /// layout pass, and a drag's many frame changes collapse into one pass.
        func listWidthChanged() {
            guard !isWidthRefreshScheduled else { return }
            isWidthRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isWidthRefreshScheduled = false
                    guard let tableView = self.tableView else { return }
                    self.configureVisibleRows(in: tableView)
                    self.invalidateRowHeights(
                        IndexSet(integersIn: 0..<tableView.numberOfRows),
                        in: tableView
                    )
                    self.scheduleRemeasure(ofVisibleRowsIn: tableView)
                }
            }
        }

        private func invalidateRowHeights(_ rows: IndexSet, in tableView: NSTableView) {
            guard !rows.isEmpty else { return }
            tableView.noteHeightOfRows(withIndexesChanged: rows)
        }

        /// Moves the table's selection to the model's snapshot without
        /// reporting it back as a user selection. Scrolls only when the focused
        /// row is not fully inside the viewport, so clicking a visible row and
        /// arrowing inside the viewport never cause a scroll or a relayout.
        private func applySelection(_ snapshot: SelectionState.Snapshot, in tableView: NSTableView) {
            guard let table = tableView as? EntryTableView else { return }
            isApplyingSelection = true

            let selectedRows: IndexSet
            if snapshot.ids.isEmpty {
                selectedRows = IndexSet()
            } else {
                var indexByID: [Int64: Int] = [:]
                indexByID.reserveCapacity(parent.rows.count)
                for (index, row) in parent.rows.enumerated() {
                    indexByID[row.id] = index
                }
                selectedRows = IndexSet(snapshot.ids.compactMap { indexByID[$0] })
            }
            if tableView.selectedRowIndexes != selectedRows {
                tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            }

            if let focus = snapshot.focus,
               let focusRow = parent.rows.firstIndex(where: { $0.id == focus })
            {
                let visibleRange = fullyVisibleRows(in: tableView)
                if SelectionRevealPolicy.rowToReveal(selectedRow: focusRow, visibleRows: visibleRange) != nil {
                    table.scrollRowToVisible(focusRow)
                }
            }
            isApplyingSelection = false
        }

        private func fullyVisibleRows(in tableView: NSTableView) -> Range<Int> {
            let visibleRect = tableView.visibleRect
            let rows = tableView.rows(in: visibleRect)
            guard rows.length > 0 else { return 0..<0 }
            var first = max(rows.location, 0)
            var last = min(rows.location + rows.length, tableView.numberOfRows)
            while first < last, tableView.rect(ofRow: first).minY < visibleRect.minY {
                first += 1
            }
            while last > first, tableView.rect(ofRow: last - 1).maxY > visibleRect.maxY {
                last -= 1
            }
            return first..<last
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.rows.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? EntryCellView
                ?? EntryCellView(identifier: Self.cellIdentifier)
            cell.configure(
                row: parent.rows[row],
                actions: parent.actions,
                language: parent.language,
                width: Self.contentWidth(in: tableView),
                font: parent.font,
                maxTextLines: parent.maxTextLines
            )
            return cell
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard parent.rows.indices.contains(row) else { return }
            parent.onRowBecameVisible(parent.rows[row].id)
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingSelection, let tableView else { return }
            let ids = Set(tableView.selectedRowIndexes.compactMap { row -> Int64? in
                guard parent.rows.indices.contains(row) else { return nil }
                return parent.rows[row].id
            })
            // AppKit has already reset `clickedRow` by the time it posts this
            // notification for a modifier click, so use the row captured before
            // the table handled the mouse-down.
            let clickedRow = tableView.clickedRowForSelection
            let clickedID = parent.rows.indices.contains(clickedRow)
                ? parent.rows[clickedRow].id
                : nil
            let focus: Int64?
            if ids.isEmpty {
                focus = nil
            } else if let clickedID, ids.contains(clickedID) {
                focus = clickedID
            } else if let current = parent.selection.focusedEntryID, ids.contains(current) {
                focus = current
            } else {
                focus = tableView.selectedRowIndexes.first.flatMap { row in
                    parent.rows.indices.contains(row) ? parent.rows[row].id : nil
                }
            }
            parent.onSelectionChange(
                ListSelectionChange(
                    clickedID: clickedID,
                    ids: ids,
                    focus: focus,
                    extending: (NSApp.currentEvent?.modifierFlags ?? []).contains(.shift),
                    command: (NSApp.currentEvent?.modifierFlags ?? []).contains(.command)
                )
            )
        }

        // MARK: Dragging rows onto a tab or external apps

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.rows.indices.contains(row) else { return nil }
            let entryID = parent.rows[row].id
            let item = NSPasteboardItem()
            item.setString(String(entryID), forType: EntryDrag.pasteboardType)

            if let entry = parent.actions.entry(entryID) {
                PasteboardBridge.attachDragTypes(from: entry.flavours, to: item)
            }
            return item
        }

        func tableView(
            _ tableView: NSTableView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forRowIndexes rowIndexes: IndexSet
        ) {
            writeDragData(forRowIndexes: rowIndexes, to: session.draggingPasteboard)
        }

        func writeDragData(forRowIndexes rowIndexes: IndexSet, to pasteboard: NSPasteboard) {
            let entries = rowIndexes.compactMap { row -> ClipboardEntry? in
                guard parent.rows.indices.contains(row) else { return nil }
                return parent.actions.entry(parent.rows[row].id)
            }
            PasteboardBridge.writeDragData(for: entries, to: pasteboard)
        }

        // A single click activates immediately when configured. Click-sequence
        // suppression ensures that a rapid double click on the same row performs
        // only one activation in total.
        @objc func handleSingleClick(_ sender: Any?) {
            guard parent.singleClickActivates else { return }
            // Command and Shift are selection gestures, not activation. With
            // the single-click preference on, toggling or extending must not
            // also paste the clicked row.
            let modifiers = (NSApp.currentEvent?.modifierFlags ?? [])
                .intersection(.deviceIndependentFlagsMask)
            guard !modifiers.contains(.command), !modifiers.contains(.shift) else { return }
            guard let tableView, parent.rows.indices.contains(tableView.clickedRow) else { return }
            let row = tableView.clickedRow
            let event = NSApp.currentEvent
            let clickCount = event?.clickCount ?? 1
            let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
            clickActivationPolicy.doubleClickInterval = NSEvent.doubleClickInterval
            guard clickActivationPolicy.shouldActivate(
                row: row,
                clickCount: clickCount,
                at: timestamp,
                singleClickActivates: parent.singleClickActivates
            ) else { return }
            parent.onActivate(parent.rows[row].id)
        }

        // Double-clicking always activates unless this click sequence already
        // activated the row on its initial single click.
        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView, parent.rows.indices.contains(tableView.clickedRow) else { return }
            let row = tableView.clickedRow
            let event = NSApp.currentEvent
            let clickCount = max(2, event?.clickCount ?? 2)
            let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
            clickActivationPolicy.doubleClickInterval = NSEvent.doubleClickInterval
            guard clickActivationPolicy.shouldActivate(
                row: row,
                clickCount: clickCount,
                at: timestamp,
                singleClickActivates: parent.singleClickActivates
            ) else { return }
            parent.onActivate(parent.rows[row].id)
        }

        // MARK: Context menu

        func contextMenu(for row: Int) -> NSMenu? {
            guard parent.rows.indices.contains(row) else { return nil }
            let entry = parent.rows[row]
            let language = parent.language
            let menu = NSMenu()
            menu.addItem(item(
                Localization.string(.menuItemNewItem, language: language),
                action: #selector(contextNewItem(_:)),
                entryID: entry.id,
                keyEquivalent: "n"
            ))
            menu.addItem(item(
                Localization.string(.menuItemEditItem, language: language),
                action: #selector(contextEditItem(_:)),
                entryID: entry.id,
                keyEquivalent: String(UnicodeScalar(NSF2FunctionKey)!),
                modifierMask: []
            ))
            menu.addItem(.separator())
            menu.addItem(item(
                Localization.string(.menuItemActivate, language: language),
                action: #selector(contextActivate(_:)),
                entryID: entry.id,
                keyEquivalent: "\r",
                modifierMask: []
            ))
            menu.addItem(item(
                Localization.string(.contextCopyToClipboard, language: language),
                action: #selector(contextCopy(_:)),
                entryID: entry.id,
                keyEquivalent: "c"
            ))
            menu.addItem(.separator())
            menu.addItem(item(
                Localization.string(entry.pinned ? .menuItemUnpin : .menuItemPin, language: language),
                action: #selector(contextTogglePin(_:)),
                entryID: entry.id,
                keyEquivalent: "p"
            ))
            let removeTitle = parent.selection.selectedEntryIDs.count > 1
                ? Localization.format(
                    .dialogRemoveItemsTitlePlural,
                    language: language,
                    parent.selection.selectedEntryIDs.count
                )
                : Localization.string(.menuItemRemove, language: language)
            menu.addItem(item(
                removeTitle,
                action: #selector(contextRemoveSelection(_:)),
                entryID: entry.id,
                keyEquivalent: "\u{8}"
            ))
            return menu
        }

        func emptyAreaContextMenu() -> NSMenu? {
            let menu = NSMenu()
            menu.addItem(item(
                Localization.string(.menuItemNewItem, language: parent.language),
                action: #selector(contextNewItem(_:)),
                entryID: -1,
                keyEquivalent: "n"
            ))
            return menu
        }

        private func item(
            _ title: String,
            action: Selector,
            entryID: Int64,
            keyEquivalent: String = "",
            modifierMask: NSEvent.ModifierFlags = [.command]
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            if !keyEquivalent.isEmpty {
                item.keyEquivalentModifierMask = modifierMask
            }
            item.target = self
            item.representedObject = NSNumber(value: entryID)
            return item
        }

        private func entryID(for sender: NSMenuItem) -> Int64? {
            (sender.representedObject as? NSNumber)?.int64Value
        }

        @objc private func contextNewItem(_ sender: NSMenuItem) {
            parent.contextActions.newItem()
        }

        @objc private func contextEditItem(_ sender: NSMenuItem) {
            guard let id = entryID(for: sender) else { return }
            parent.contextActions.editItem(id)
        }

        @objc private func contextActivate(_ sender: NSMenuItem) {
            guard let id = entryID(for: sender) else { return }
            parent.onActivate(id)
        }

        @objc private func contextCopy(_ sender: NSMenuItem) {
            guard let id = entryID(for: sender) else { return }
            parent.onCopy(id)
        }

        @objc private func contextTogglePin(_ sender: NSMenuItem) {
            guard let id = entryID(for: sender) else { return }
            parent.actions.togglePin(id)
        }

        @objc private func contextRemoveSelection(_ sender: NSMenuItem) {
            parent.contextActions.removeSelection()
        }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            switch menuItem.action {
            case #selector(contextNewItem(_:)):
                return parent.contextActions.canCreateNewItem()
            case #selector(contextEditItem(_:)):
                guard let id = entryID(for: menuItem) else { return false }
                let availability = parent.contextActions.editItemAvailability(id)
                menuItem.title = availability.title
                return availability.isEnabled
            default:
                return true
            }
        }
    }
}

// MARK: - Cell

/// A reused cell that hosts one SwiftUI row.
private final class EntryCellView: NSTableCellView {
    private let hosting: NSHostingView<EntryRowContent>

    init(identifier: NSUserInterfaceItemIdentifier) {
        hosting = NSHostingView(
            rootView: EntryRowContent(
                row: .placeholder,
                actions: .none,
                language: .english,
                width: 0,
                font: nil
            )
        )
        super.init(frame: .zero)
        self.identifier = identifier
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(
        row: EntryRow,
        actions: EntryRowActions,
        language: AppLanguage,
        width: CGFloat,
        font: NSFont?,
        maxTextLines: Int = EntryRowMetrics.defaultMaxTextLines
    ) {
        hosting.rootView = EntryRowContent(
            row: row,
            actions: actions,
            language: language,
            width: width,
            font: font,
            maxTextLines: maxTextLines
        )
    }

    /// The height this row's content needs at the width it was configured with.
    ///
    /// The hosting view fills the cell, so the cell's fitting height is the
    /// height of the SwiftUI row exactly; the table asks for this after a
    /// reconfigure to keep the row's remembered height in step with its content.
    var preferredHeight: CGFloat { fittingSize.height }
}

// MARK: - Scroll view

/// The list's scroll view, with the window's transient banner floating over the
/// top rows.
///
/// The banner is an ordinary AppKit subview of this scroll view, not a SwiftUI
/// overlay: that is what makes it genuinely click-through. A point the banner
/// does not claim (everything except its own buttons, see
/// `NoticeBannerView.hitTest(_:)`) falls through the AppKit hit-test chain to the
/// clip view and the row under the pointer, so the list keeps responding while a
/// message is on screen.
final class EntryListScrollView: NSScrollView {
    let banner = NoticeBannerView()

    /// Gap between the banner and the edges of the list.
    private static let inset: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(banner)
    }

    /// Keeps the banner above the clip view. Setting `documentView` installs the
    /// clip view as a subview, and a subview added later draws on top of the
    /// banner, so the list re-raises it after that.
    func keepBannerOnTop() {
        addSubview(banner, positioned: .above, relativeTo: nil)
    }

    func configureBanner(
        _ content: NoticeBannerContent?,
        onAction: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        banner.configure(content, onAction: onAction, onDismiss: onDismiss)
        positionBanner()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        positionBanner()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        positionBanner()
    }

    /// Puts the banner over the top rows, inside the list's own bounds.
    private func positionBanner() {
        let width = max(0, bounds.width - Self.inset * 2)
        guard !banner.isHidden, width > 0 else {
            banner.frame = .zero
            return
        }
        let height = banner.height(forWidth: width)
        let y = isFlipped ? bounds.minY + Self.inset : bounds.maxY - Self.inset - height
        banner.frame = NSRect(
            x: Self.inset,
            y: y,
            width: width,
            height: height
        )
        banner.layout(in: width)
    }
}

// MARK: - Table view

/// Table view that routes right clicks to the row under the pointer and lets
/// the coordinator know whether it holds keyboard focus.
final class EntryTableView: NSTableView {
    var contextMenuProvider: ((Int) -> NSMenu?)?
    var emptyAreaMenuProvider: (() -> NSMenu?)?
    var focusChangeHandler: ((Bool) -> Void)?
    /// Called when the table's width changed, so the rows can be drawn and
    /// measured at the new width.
    var widthChangeHandler: (() -> Void)?

    /// The row under the pointer at mouse-down. AppKit only keeps `clickedRow`
    /// valid for part of the click, so the selection notification reads this
    /// instead. It is cleared once the click sequence ends (or a key starts a
    /// keyboard selection) so keyboard changes are not mistaken for clicks.
    private var mouseDownRow = -1

    /// The row the user is clicking, falling back to AppKit's own value when
    /// the table changed its selection outside a mouse-down.
    var clickedRowForSelection: Int {
        mouseDownRow >= 0 ? mouseDownRow : clickedRow
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) >= 0.5
        super.setFrameSize(newSize)
        if widthChanged { widthChangeHandler?() }
    }

    #if COPYQMAC_TESTING
    var invalidatedRowHeights = IndexSet()

    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        invalidatedRowHeights.formUnion(indexSet)
        super.noteHeightOfRows(withIndexesChanged: indexSet)
    }
    #endif

    func beginMouseDown(at point: NSPoint) {
        mouseDownRow = row(at: point)
    }

    override func mouseDown(with event: NSEvent) {
        beginMouseDown(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // AppKit can post the selection notification while it finishes the
        // click, so let the current event drain before dropping the row.
        DispatchQueue.main.async { [weak self] in
            self?.mouseDownRow = -1
        }
    }

    override func keyDown(with event: NSEvent) {
        mouseDownRow = -1
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // A right click can select the row it opened on. Record that row so
        // the selection notification focuses it too.
        mouseDownRow = row
        guard row >= 0 else { return emptyAreaMenuProvider?() }
        // Right clicking inside a multi-selection keeps it, so the menu can act
        // on every highlighted row; right clicking elsewhere selects that row.
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?(row)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChangeHandler?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChangeHandler?(false) }
        return accepted
    }
}
