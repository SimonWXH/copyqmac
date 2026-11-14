// The main CopyQmac window. Layout A is the classic arrangement: a tab strip,
// a filter field, the numbered item list, a preview pane with the note editor,
// and a status bar. Layout B moves the tab list into a sidebar, the filter into
// a unified toolbar, and the preview and note into a trailing inspector.
// `Preferences.windowLayout` chooses between them.
//
// The window is the primary surface (the menu-bar item only shows and hides
// it). Styling follows macOS 26: system font, Liquid Glass surfaces, and the
// native blue selection highlight in the list.

import AppKit
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var renameText = ""

    var body: some View {
        let lang = model.preferences.language
        Group {
            switch model.preferences.windowLayout {
            case .layoutA:
                LayoutAView(
                    model: model,
                    searchFocused: $searchFocused,
                    onDismiss: onDismiss
                )
            case .layoutB:
                LayoutBView(
                    model: model,
                    searchFocused: $searchFocused,
                    onDismiss: onDismiss
                )
            }
        }
        .background(WindowBackground())
        // The smallest size the layout can take. The window uses it as its
        // minimum size, so it cannot be dragged into a shape the list, the
        // preview pane, and the note editor do not fit in.
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            model.applyRichTextAppearance(RichTextAppearance(colorScheme: colorScheme))
        }
        .onChange(of: colorScheme) { _, scheme in
            model.applyRichTextAppearance(RichTextAppearance(colorScheme: scheme))
        }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
        .onChange(of: searchFocused) { _, focused in model.setFilterFocused(focused) }
        .onChange(of: model.preferences.windowLayout) { _, _ in model.setSidebarFocused(false) }
        .onChange(of: model.pendingRenameTabID) { _, newValue in
            guard let newValue,
                  let tab = model.tabs.first(where: { $0.id == newValue }) else { return }
            renameText = tab.name
        }
        .alert(Localization.string(.alertRenameTabTitle, language: lang), isPresented: renameBinding) {
            TextField(Localization.string(.alertRenameTabPlaceholder, language: lang), text: $renameText)
            Button(Localization.string(.alertRenameTabConfirm, language: lang)) {
                if let id = model.pendingRenameTabID,
                   let tab = model.tabs.first(where: { $0.id == id }) {
                    model.renameTab(tab, to: renameText)
                }
                model.pendingRenameTabID = nil
            }
            Button(Localization.string(.alertRenameTabCancel, language: lang), role: .cancel) { model.pendingRenameTabID = nil }
        } message: {
            Text(Localization.string(.alertRenameTabMessage, language: lang))
        }
        .sheet(item: $model.pendingTextEdit) { request in
            TextEditSheet(
                request: request,
                language: model.preferences.language,
                font: model.preferences.editorFont,
                onSave: { submission in model.commitTextEdit(submission) },
                onCancel: { model.cancelTextEdit() }
            )
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { model.pendingRenameTabID != nil },
            set: { if !$0 { model.pendingRenameTabID = nil } }
        )
    }
}

// MARK: - Window background

/// The body of the window.
///
/// It is opaque on purpose: the list, the preview pane, and the status bar
/// must not show the desktop wallpaper through them. The glass surfaces are
/// accents inside the window (the tab chips, the notice, the note editor),
/// not the window itself.
private struct WindowBackground: View {
    var body: some View {
        DesignTokens.Colors.windowBackground
    }
}

// MARK: - Layout A (Classic)

private struct LayoutAView: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var searchFocused: Bool
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(model: model)
            Divider().opacity(0.35)
            FilterBarView(model: model, searchFocused: $searchFocused)
            Divider().opacity(0.35)
            ItemListView(model: model, onDismiss: onDismiss)
            Divider().opacity(0.35)
            PreviewPaneView(model: model, selection: model.selection)
            Divider().opacity(0.35)
            StatusBarView(model: model)
        }
    }
}

// MARK: - Sidebar Toggle Button

struct SidebarToggleButton: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    let language: AppLanguage

    var isSidebarVisible: Bool {
        columnVisibility != .detailOnly
    }

    func toggle() {
        columnVisibility = isSidebarVisible ? .detailOnly : .all
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 14))
                .foregroundStyle(isSidebarVisible ? DesignTokens.Colors.selection : DesignTokens.Colors.label)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous)
                        .fill(isSidebarVisible ? DesignTokens.Colors.selection.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(Localization.string(.sidebarToggleHelp, language: language))
    }
}

// MARK: - Layout B (Sidebar + Inspector)

struct LayoutBView: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var searchFocused: Bool
    let onDismiss: () -> Void

    @State private var internalColumnVisibility = NavigationSplitViewVisibility.all
    private let externalColumnVisibility: Binding<NavigationSplitViewVisibility>?

    @State private var isInspectorVisible = true
    @State private var noteFocused = false
    @State private var dragRatio: Double?

    init(
        model: AppModel,
        searchFocused: FocusState<Bool>.Binding,
        onDismiss: @escaping () -> Void,
        columnVisibility: Binding<NavigationSplitViewVisibility>? = nil
    ) {
        self.model = model
        self._searchFocused = searchFocused
        self.onDismiss = onDismiss
        self.externalColumnVisibility = columnVisibility
    }

    private var effectiveColumnVisibility: Binding<NavigationSplitViewVisibility> {
        externalColumnVisibility ?? $internalColumnVisibility
    }

    private var selectedEntry: ClipboardEntry? {
        guard let id = model.selection.selectedEntryID else { return nil }
        return model.entries.first { $0.id == id }
    }

    var body: some View {
        let lang = model.preferences.language
        NavigationSplitView(columnVisibility: effectiveColumnVisibility) {
            SidebarTabView(model: model)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                // Unified toolbar 52pt
                HStack(spacing: DesignTokens.Spacing.medium) {
                    // Filter search field
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(
                            Localization.string(.filterItemsPlaceholder, language: lang),
                            text: $model.searchText
                        )
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        if !model.searchText.isEmpty {
                            Button {
                                model.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(Localization.string(.filterClearHelp, language: lang))
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.medium)
                    .padding(.vertical, DesignTokens.Spacing.compact)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: DesignTokens.Spacing.hairline)
                    )

                    // Scope picker (Current tab / All tabs)
                    Picker(
                        Localization.string(.scopePickerLabel, language: lang),
                        selection: Binding(
                            get: { model.preferences.searchAllTabs ? 1 : 0 },
                            set: { model.setSearchAllTabs($0 == 1) }
                        )
                    ) {
                        Text(Localization.string(.scopeCurrentTab, language: lang)).tag(0)
                        Text(Localization.string(.scopeAllTabs, language: lang)).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)

                    Spacer(minLength: DesignTokens.Spacing.medium)

                    // Inspector toggle button
                    Button {
                        if isInspectorVisible, model.isEditingNote {
                            model.endNoteEditing()
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isInspectorVisible.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.trailing")
                            .font(.system(size: 14))
                            .foregroundStyle(isInspectorVisible ? DesignTokens.Colors.selection : DesignTokens.Colors.label)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous)
                                    .fill(isInspectorVisible ? DesignTokens.Colors.selection.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(Localization.string(.inspectorToggleHelp, language: lang))
                }
                .padding(.horizontal, DesignTokens.Spacing.bar)
                .frame(height: 52)

                Divider().opacity(0.35)

                // Center column + trailing inspector
                HStack(spacing: 0) {
                    ItemListView(model: model, onDismiss: onDismiss)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isInspectorVisible {
                        Divider().opacity(0.35)

                        // Trailing inspector 280pt
                        VStack(spacing: 0) {
                            InspectorMetadataBlock(
                                entry: selectedEntry,
                                model: model,
                                language: lang
                            )

                            if selectedEntry != nil {
                                Divider().opacity(0.35)
                            }

                            GeometryReader { geo in
                                let totalHeight = max(0, geo.size.height - 7)
                                let ratio = dragRatio ?? model.preferences.inspectorSplitRatio
                                let heights = InspectorSplitLayout.paneHeights(
                                    availableHeight: totalHeight,
                                    ratio: ratio
                                )

                                VStack(spacing: 0) {
                                    InspectorPreviewPane(model: model, selectedEntry: selectedEntry)
                                        .frame(height: heights.preview)
                                        .clipped()

                                    InspectorDividerRepresentable(
                                        availableHeight: totalHeight,
                                        currentRatio: InspectorSplitLayout.displayedRatio(
                                            availableHeight: totalHeight,
                                            ratio: ratio
                                        ),
                                        onRatioChange: { dragRatio = $0 },
                                        onRatioCommit: { newRatio in
                                            model.updatePreferences { $0.inspectorSplitRatio = newRatio }
                                            dragRatio = nil
                                        },
                                        onReset: {
                                            model.updatePreferences { $0.inspectorSplitRatio = InspectorSplitLayout.defaultRatio }
                                            dragRatio = nil
                                        }
                                    )
                                    .frame(height: 7)

                                    InspectorNotePane(
                                        model: model,
                                        selectedEntry: selectedEntry,
                                        noteFocused: $noteFocused
                                    )
                                    .frame(height: heights.note)
                                }
                            }
                        }
                        .frame(width: 280)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                    }
                }

                Divider().opacity(0.35)
                StatusBarView(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                SidebarToggleButton(
                    columnVisibility: effectiveColumnVisibility,
                    language: lang
                )
            }
        }
        .onChange(of: model.focusNoteToken) { _, _ in noteFocused = true }
        .onChange(of: model.noteBlurToken) { _, _ in noteFocused = false }
    }
}

// MARK: - Sidebar

private struct SidebarTabView: View {
    @ObservedObject var model: AppModel
    @FocusState private var listFocused: Bool

    var body: some View {
        let lang = model.preferences.language
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedTabID },
                set: {
                    if let id = $0 {
                        model.selectTab(id)
                        model.setSidebarFocused(true)
                    }
                }
            )) {
                ForEach(model.tabs) { tab in
                    SidebarTabRow(model: model, tab: tab)
                        .tag(tab.id)
                }
                .onMove { indices, destination in
                    reorderTabs(from: indices, to: destination)
                }
            }
            .listStyle(.sidebar)
            .focused($listFocused)
            .onChange(of: listFocused) { _, focused in
                model.setSidebarFocused(focused)
            }

            Divider().opacity(0.35)

            HStack {
                Button {
                    model.addTab(named: "Tab \(model.tabs.count + 1)")
                } label: {
                    Label(
                        Localization.string(.menuTabsNewTab, language: lang),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.borderless)
                .font(DesignTokens.Typography.caption)
                .help(Localization.string(.tabBarNewTabHelp, language: lang))

                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.vertical, DesignTokens.Spacing.small)
        }
    }

    private func reorderTabs(from source: IndexSet, to destination: Int) {
        for index in source {
            let delta = destination > index ? destination - index - 1 : destination - index
            guard delta != 0 else { continue }
            let step = delta > 0 ? 1 : -1
            let tab = model.tabs[index]
            for _ in 0..<abs(delta) {
                model.moveTab(tab, delta: step)
            }
        }
    }
}

enum TabContextMenu {
    struct Titles: Equatable, Sendable {
        let rename: String
        let moveBackward: String
        let moveForward: String
        let useAsCaptureTab: String
        let compareSyncFolder: String
        let removeTab: String
    }

    static func titles(for layout: WindowLayout, language: AppLanguage) -> Titles {
        let moveBackwardKey: CatalogKey
        let moveForwardKey: CatalogKey
        switch layout {
        case .layoutB:
            moveBackwardKey = .tabContextMoveUp
            moveForwardKey = .tabContextMoveDown
        case .layoutA:
            moveBackwardKey = .tabContextMoveLeft
            moveForwardKey = .tabContextMoveRight
        }
        return Titles(
            rename: Localization.string(.settingsTabRenameButton, language: language),
            moveBackward: Localization.string(moveBackwardKey, language: language),
            moveForward: Localization.string(moveForwardKey, language: language),
            useAsCaptureTab: Localization.string(.menuTabsUseAsCaptureTab, language: language),
            compareSyncFolder: Localization.string(.tabContextCompareSyncFolder, language: language),
            removeTab: Localization.string(.menuTabsRemoveTab, language: language)
        )
    }
}

private struct SidebarTabRow: View {
    @ObservedObject var model: AppModel
    let tab: ClipboardTab
    @State private var isDropTarget = false

    private var acceptsDrop: Bool { model.canMoveSelection(toTabID: tab.id) }
    private var count: Int { model.tabEntryCounts[tab.id] ?? 0 }

    var body: some View {
        let lang = model.preferences.language
        HStack(spacing: DesignTokens.Spacing.small) {
            if tab.isDefault {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignTokens.Colors.notice)
                    .help(Localization.string(.tabChipCaptureHelp, language: lang))
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(tab.name)
                .font(DesignTokens.Typography.callout)
                .lineLimit(1)

            Spacer(minLength: DesignTokens.Spacing.xxSmall)

            Text("\(count)")
                .font(DesignTokens.Typography.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DesignTokens.Spacing.compact)
                .padding(.vertical, DesignTokens.Spacing.hairline)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                )
        }
        .padding(.vertical, DesignTokens.Spacing.xxSmall)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .strokeBorder(
                    isDropTarget && acceptsDrop ? DesignTokens.Colors.selection : Color.clear,
                    lineWidth: isDropTarget && acceptsDrop ? 2 : 1
                )
                .allowsHitTesting(false)
        )
        .onTapGesture {
            model.selectTab(tab.id)
            model.setSidebarFocused(true)
        }
        .onDrop(of: [EntryDrag.contentType], isTargeted: $isDropTarget) { _ in
            guard acceptsDrop else { return false }
            Task { @MainActor in
                model.moveSelection(toTabID: tab.id)
            }
            return true
        }
        .contextMenu {
            let titles = TabContextMenu.titles(for: model.preferences.windowLayout, language: lang)
            Button(titles.rename) {
                model.pendingRenameTabID = tab.id
            }
            Button(titles.moveBackward) {
                model.moveTab(tab, delta: -1)
            }
            Button(titles.moveForward) {
                model.moveTab(tab, delta: 1)
            }
            Divider()
            Button(titles.useAsCaptureTab) {
                model.setCaptureTab(tab)
            }
            .disabled(tab.isDefault)
            Divider()
            Button(titles.compareSyncFolder) {
                model.requestResyncTab(tab.id)
            }
            .disabled((tab.syncFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Button(titles.removeTab, role: .destructive) {
                model.removeTab(tab)
            }
            .disabled(model.tabs.count <= 1)
        }
    }
}

// MARK: - Inspector Components

private struct InspectorMetadataBlock: View {
    let entry: ClipboardEntry?
    @ObservedObject var model: AppModel
    let language: AppLanguage

    var body: some View {
        if let entry = entry {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                let presentation = model.presentation(for: entry)
                let totalBytes = entry.flavours.reduce(0) { $0 + Int64($1.uncompressedByteCount) }
                let detailCount = metadataDetailCount(presentation: presentation, language: language)

                HStack(spacing: DesignTokens.Spacing.small) {
                    if let kind = presentation?.kind {
                        Text(Localization.contentKindLabel(kind, language: language))
                            .font(DesignTokens.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(DesignTokens.Colors.selection)
                            .padding(.horizontal, DesignTokens.Spacing.compact)
                            .padding(.vertical, DesignTokens.Spacing.xxSmall)
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous)
                                    .fill(DesignTokens.Colors.selection.opacity(0.12))
                            )
                    }

                    Spacer(minLength: 0)

                    if entry.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.Colors.notice)
                    }
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(Localization.byteCount(totalBytes, language: language))
                            .font(DesignTokens.Typography.caption2)
                            .foregroundStyle(.secondary)

                        if let detailCount {
                            Text("•").foregroundStyle(.tertiary)
                            Image(systemName: detailCount.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(detailCount.label)
                                .font(DesignTokens.Typography.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let presentation {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Image(systemName: "clock")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(presentation.relativeTime)
                                .font(DesignTokens.Typography.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(DesignTokens.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metadataDetailCount(
        presentation: EntryPresentation?,
        language: AppLanguage
    ) -> (icon: String, label: String)? {
        if let lineCount = presentation?.lineCount {
            return ("text.alignleft", Localization.lineCount(lineCount, language: language))
        }
        if presentation?.kind == .files, let fileCount = presentation?.fileCount, fileCount > 0 {
            return ("doc.on.doc", Localization.fileCount(fileCount, language: language))
        }
        return nil
    }
}

private struct InspectorPreviewPane: View {
    @ObservedObject var model: AppModel
    let selectedEntry: ClipboardEntry?

    var body: some View {
        let lang = model.preferences.language
        VStack(alignment: .leading, spacing: 0) {
            if let entry = selectedEntry {
                let presentation = model.presentation(for: entry)
                switch presentation?.kind {
                case .image:
                    if let previewImage = model.selectedPreviewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                    } else if let thumbnail = model.thumbnail(for: entry, maxSize: 240) {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                    } else {
                        Text(Localization.string(.previewImageUnavailable, language: lang))
                            .font(DesignTokens.Typography.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                case .files:
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                            ForEach(Array((presentation?.fileURLs ?? []).enumerated()), id: \.offset) { _, url in
                                HStack(spacing: DesignTokens.Spacing.small) {
                                    if let icon = model.fileIcon(forPath: url.path) {
                                        Image(nsImage: icon)
                                            .resizable().frame(width: 16, height: 16)
                                    }
                                    Text(url.lastPathComponent)
                                        .font(DesignTokens.Typography.callout)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(DesignTokens.Spacing.small)
                    }
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let richText = model.richText(for: entry) {
                                Text(richText.preview)
                                    .font(DesignTokens.Typography.callout)
                                    .textSelection(.enabled)
                            } else {
                                Text(presentation?.searchText ?? presentation?.primaryText ?? "")
                                    .font(DesignTokens.Typography.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(DesignTokens.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                Text(Localization.string(.previewSelectPrompt, language: lang))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

private struct InspectorNotePane: View {
    @ObservedObject var model: AppModel
    let selectedEntry: ClipboardEntry?
    @Binding var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Label(
                Localization.string(.previewNoteLabel, language: model.preferences.language),
                systemImage: "note.text"
            )
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)

            PlainTextEditor(
                text: noteBinding,
                font: PlainTextEditor.noteFont,
                isFocused: $noteFocused,
                onEditingChanged: { model.setNoteEditing($0) }
            )
            .frame(maxHeight: .infinity)
            .padding(DesignTokens.Spacing.small)
            .glassSurface(cornerRadius: DesignTokens.Radius.panel)
            .disabled(selectedEntry == nil)
        }
        .padding(DesignTokens.Spacing.small)
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { selectedEntry?.note ?? "" },
            set: { model.setNoteDraft($0) }
        )
    }
}

// MARK: - Inspector Split Divider

final class InspectorDividerNSView: NSView {
    var availableHeight: CGFloat = 0
    var currentRatio: Double = InspectorSplitLayout.defaultRatio
    var onRatioChange: ((Double) -> Void)?
    var onRatioCommit: ((Double) -> Void)?
    var onReset: (() -> Void)?

    private var dragAnchorY: CGFloat = 0
    private var initialRatio: Double = InspectorSplitLayout.defaultRatio
    private var lastReportedRatio: Double?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        dragAnchorY = event.locationInWindow.y
        initialRatio = currentRatio
        isDragging = true
        NSCursor.resizeUpDown.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, availableHeight > 0 else { return }
        let newRatio = InspectorSplitLayout.ratio(
            startRatio: initialRatio,
            pointerDelta: dragAnchorY - event.locationInWindow.y,
            availableHeight: availableHeight
        )
        lastReportedRatio = newRatio
        onRatioChange?(newRatio)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if let ratio = lastReportedRatio {
            lastReportedRatio = nil
            onRatioCommit?(ratio)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let gripWidth: CGFloat = 22
        let gripHeight: CGFloat = 2
        let gripX = (bounds.width - gripWidth) / 2
        let gripY = (bounds.height - gripHeight) / 2
        let gripRect = NSRect(x: gripX, y: gripY, width: gripWidth, height: gripHeight)
        let gripPath = NSBezierPath(roundedRect: gripRect, xRadius: 1, yRadius: 1)
        NSColor.separatorColor.withAlphaComponent(0.6).setFill()
        gripPath.fill()
    }
}

private struct InspectorDividerRepresentable: NSViewRepresentable {
    let availableHeight: CGFloat
    let currentRatio: Double
    let onRatioChange: (Double) -> Void
    let onRatioCommit: (Double) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> InspectorDividerNSView {
        let view = InspectorDividerNSView()
        view.availableHeight = availableHeight
        view.currentRatio = currentRatio
        view.onRatioChange = onRatioChange
        view.onRatioCommit = onRatioCommit
        view.onReset = onReset
        return view
    }

    func updateNSView(_ nsView: InspectorDividerNSView, context: Context) {
        nsView.availableHeight = availableHeight
        nsView.currentRatio = currentRatio
        nsView.onRatioChange = onRatioChange
        nsView.onRatioCommit = onRatioCommit
        nsView.onReset = onReset
    }
}

// MARK: - Tab bar

private struct TabBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lang = model.preferences.language
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.small) {
                ForEach(model.tabs) { tab in
                    TabChip(model: model, tab: tab)
                }
                Button {
                    model.addTab(named: "Tab \(model.tabs.count + 1)")
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help(Localization.string(.tabBarNewTabHelp, language: lang))
                .padding(.leading, DesignTokens.Spacing.xxSmall)
            }
            .padding(.horizontal, DesignTokens.Spacing.large)
            .padding(.vertical, DesignTokens.Spacing.medium)
        }
    }
}

private struct TabChip: View {
    @ObservedObject var model: AppModel
    let tab: ClipboardTab
    @State private var isDropTarget = false

    private var isSelected: Bool { tab.id == model.selectedTabID }
    private var acceptsDrop: Bool { model.canMoveSelection(toTabID: tab.id) }

    var body: some View {
        let lang = model.preferences.language
        Button {
            model.selectTab(tab.id)
        } label: {
            HStack(spacing: DesignTokens.Spacing.compact) {
                if tab.isDefault {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 9, weight: .bold))
                        .help(Localization.string(.tabChipCaptureHelp, language: lang))
                }
                Text(tab.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.card)
            .padding(.vertical, DesignTokens.Spacing.compact)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : DesignTokens.Colors.label)
        .glassSurface(cornerRadius: DesignTokens.Radius.panel, tint: isSelected ? DesignTokens.Colors.selection : nil, interactive: true)
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .strokeBorder(
                    isDropTarget && acceptsDrop
                        ? DesignTokens.Colors.selection
                        : (isSelected ? DesignTokens.Colors.selection : Color.clear),
                    lineWidth: isDropTarget && acceptsDrop ? 2 : 1
                )
        )
        // Dropping the list's selection here moves every selected entry into
        // this tab. The files follow the same rules as the menu command.
        .onDrop(of: [EntryDrag.contentType], isTargeted: $isDropTarget) { _ in
            guard acceptsDrop else { return false }
            // Let the drop session finish before a confirmation alert (or the
            // list reload) runs; a modal panel inside the drop callback can
            // leave the drag session stuck.
            Task { @MainActor in
                model.moveSelection(toTabID: tab.id)
            }
            return true
        }
        .contextMenu {
            let titles = TabContextMenu.titles(for: model.preferences.windowLayout, language: lang)
            Button(titles.rename) {
                model.pendingRenameTabID = tab.id
            }
            Button(titles.moveBackward) {
                model.moveTab(tab, delta: -1)
            }
            Button(titles.moveForward) {
                model.moveTab(tab, delta: 1)
            }
            Divider()
            Button(titles.useAsCaptureTab) {
                model.setCaptureTab(tab)
            }
            .disabled(tab.isDefault)
            Divider()
            Button(titles.compareSyncFolder) {
                model.requestResyncTab(tab.id)
            }
            .disabled((tab.syncFolder ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            Button(titles.removeTab, role: .destructive) {
                model.removeTab(tab)
            }
            .disabled(model.tabs.count <= 1)
        }
    }
}

// MARK: - Filter bar

private struct FilterBarView: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var searchFocused: Bool

    var body: some View {
        let lang = model.preferences.language
        HStack(spacing: DesignTokens.Spacing.medium) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                Localization.string(.filterItemsPlaceholder, language: lang),
                text: $model.searchText
            )
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Localization.string(.filterClearHelp, language: lang))
            }
            Spacer(minLength: DesignTokens.Spacing.medium)
            Toggle(Localization.string(.filterAllTabsToggle, language: lang), isOn: Binding(
                get: { model.preferences.searchAllTabs },
                set: { model.setSearchAllTabs($0) }
            ))
            .toggleStyle(.checkbox)
            .help(Localization.string(.filterSearchAllTabsHelp, language: lang))
        }
        .padding(.horizontal, DesignTokens.Spacing.bar)
        .padding(.vertical, DesignTokens.Spacing.small)
    }
}

// MARK: - Item list

private struct ItemListView: View {
    @ObservedObject var model: AppModel
    let onDismiss: () -> Void

    var body: some View {
        let lang = model.preferences.language
        Group {
            if model.entries.isEmpty {
                VStack(spacing: DesignTokens.Spacing.medium) {
                    // The empty list has no scroll view for the banner to float
                    // over, so it sits above the empty-state content instead.
                    if let banner = banner {
                        NoticeBannerHost(
                            content: banner,
                            onAction: { model.grantAccessibility() },
                            onDismiss: { model.dismissNotice() }
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DesignTokens.Spacing.large)
                        .padding(.top, DesignTokens.Spacing.medium)
                    }
                    Image(systemName: "clipboard")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(model.searchText.isEmpty
                        ? Localization.string(.emptyStateNoItems, language: lang)
                        : Localization.string(.emptyStateNoMatches, language: lang))
                        .foregroundStyle(.secondary)
                    if model.searchText.isEmpty {
                        Button(Localization.string(.emptyStateCreateItem, language: lang)) {
                            model.requestNewItem()
                        }
                        .buttonStyle(.link)
                        .font(DesignTokens.Typography.callout)
                        .disabled(!model.canCreateNewItem)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contextMenu {
                    if model.searchText.isEmpty && model.canCreateNewItem {
                        Button(Localization.string(.menuItemNewItem, language: lang)) {
                            model.requestNewItem()
                        }
                    }
                }
            } else {
                // The list is native AppKit on purpose; see EntryListView for
                // why a SwiftUI List could not keep selection instant.
                EntryListView(
                    rows: model.rows,
                    rowsRevision: model.rowsRevision,
                    selection: model.selection,
                    font: model.preferences.itemListFont.nsFont,
                    singleClickActivates: model.preferences.activation.singleClickActivates,
                    language: lang,
                    actions: EntryRowActions(
                        togglePin: { id in
                            guard let entry = model.entry(id: id) else { return }
                            model.togglePin(entry)
                        },
                        remove: { id in
                            guard let entry = model.entry(id: id) else { return }
                            model.remove(entry)
                        },
                        thumbnail: { id in model.rowThumbnail(for: id) }
                    ),
                    contextActions: EntryContextActions(
                        newItem: { model.requestNewItem() },
                        editItem: { id in
                            guard model.entry(id: id) != nil else { return }
                            model.focusEntry(id)
                            model.requestEditSelectedEntry()
                        },
                        editItemAvailability: { id in model.editItemAvailability(for: id) },
                        canCreateNewItem: { model.canCreateNewItem },
                        removeSelection: { model.removeSelected() }
                    ),
                    onSelectionChange: { change in
                        model.applyListSelection(change)
                    },
                    onActivate: { id in
                        guard model.entry(id: id) != nil else { return }
                        model.select(id)
                        model.activate(id, dismiss: onDismiss)
                    },
                    onCopy: { id in model.copyEntry(id) },
                    onFocusChange: { model.setListFocused($0) },
                    onRowBecameVisible: { model.ensureRowContent(for: $0) },
                    banner: banner,
                    onBannerAction: { model.grantAccessibility() },
                    onBannerDismiss: { model.dismissNotice() }
                )
            }
        }
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    /// The transient message the window is showing, if any. The list draws it
    /// itself so it can float over the top rows without taking pointer input
    /// away from them.
    private var banner: NoticeBannerContent? {
        let parts = model.noticeParts
        guard !parts.isEmpty else { return nil }
        return NoticeBannerContent(parts: parts, language: model.preferences.language)
    }
}

// MARK: - Preview pane

private struct PreviewPaneView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var selection: SelectionState
    @State private var noteFocused = false

    private var selectedEntry: ClipboardEntry? {
        guard let id = selection.selectedEntryID else { return nil }
        return model.entries.first { $0.id == id }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.large) {
            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()

            noteEditor
                .frame(width: 240)
        }
        .padding(DesignTokens.Spacing.large)
        .frame(height: 170)
        // The note-editing session is started by the editor itself, when its text
        // view takes or loses focus, not from here: a SwiftUI state round trip is
        // slower than the first keystroke, and the model drops a draft that
        // arrives before the session exists.
        .onChange(of: model.focusNoteToken) { _, _ in noteFocused = true }
        .onChange(of: model.noteBlurToken) { _, _ in noteFocused = false }
    }

    @ViewBuilder
    private var previewContent: some View {
        let lang = model.preferences.language
        if let entry = selectedEntry {
            let presentation = model.presentation(for: entry)
            switch presentation?.kind {
            case .image:
                if let previewImage = model.selectedPreviewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                } else if let thumbnail = model.thumbnail(for: entry, maxSize: 140) {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.Radius.media, style: .continuous)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                } else {
                    Text(Localization.string(.previewImageUnavailable, language: lang))
                        .foregroundStyle(.secondary)
                }
            case .files:
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
                        ForEach(Array((presentation?.fileURLs ?? []).enumerated()), id: \.offset) { _, url in
                            HStack(spacing: DesignTokens.Spacing.small) {
                                if let icon = model.fileIcon(forPath: url.path) {
                                    Image(nsImage: icon)
                                        .resizable().frame(width: 16, height: 16)
                                }
                                Text(url.lastPathComponent).font(DesignTokens.Typography.callout).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let richText = model.richText(for: entry) {
                            // HTML and RTF keep their fonts, headings, and
                            // colours here, the way CopyQ previews a rich item.
                            Text(richText.preview)
                                .textSelection(.enabled)
                        } else {
                            Text(presentation?.searchText ?? presentation?.primaryText ?? "")
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        } else {
            Text(Localization.string(.previewSelectPrompt, language: lang))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xSmall) {
            Label(
                Localization.string(.previewNoteLabel, language: model.preferences.language),
                systemImage: "note.text"
            )
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            PlainTextEditor(
                text: noteBinding,
                font: PlainTextEditor.noteFont,
                isFocused: $noteFocused,
                onEditingChanged: { model.setNoteEditing($0) }
            )
                .frame(maxHeight: .infinity)
                .padding(DesignTokens.Spacing.small)
                .glassSurface(cornerRadius: DesignTokens.Radius.panel)
                .disabled(selectedEntry == nil)
        }
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { selectedEntry?.note ?? "" },
            set: { model.setNoteDraft($0) }
        )
    }
}

// MARK: - Status bar

private struct StatusBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let lang = model.preferences.language
        HStack(spacing: DesignTokens.Spacing.large) {
            Text(Localization.itemCount(model.entries.count, language: lang))
            if let tab = model.selectedTab {
                Text(Localization.tabInfo(name: tab.name, isDefault: tab.isDefault, language: lang))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let exportStatus = model.exportStatus {
                Text(exportStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(exportStatus)
            }
            // The record of the last failure. The banner explains it for a few
            // seconds; this stays until the user has read it and clicks it away,
            // so an error is never lost just because nobody was looking.
            if model.showsFailureStatusItem, let failure = model.failureNotice {
                Button {
                    model.dismissFailureNotice()
                } label: {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.destructive)
                .help(Localization.format(.statusBarDismissTooltip, language: lang, failure))
            }
            // The persistent surface for a missing Accessibility permission.
            // It stays quiet while the permission banner is on screen - the
            // banner already explains the same thing - and takes over once the
            // banner fades. A granted app shows no accessibility text here.
            if model.showsAccessibilityStatusItem {
                Button {
                    model.grantAccessibility()
                } label: {
                    Label(
                        Localization.string(.statusBarAccessibilityNotGranted, language: lang),
                        systemImage: "lock.shield"
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.notice)
                .help(Localization.string(.statusBarAccessibilityHelp, language: lang))
            }
            Text(Localization.hotKeyLabel(model.preferences.hotKeyDisplayLabel, language: lang))
                .foregroundStyle(.secondary)
        }
        .font(DesignTokens.Typography.caption)
        .padding(.horizontal, DesignTokens.Spacing.bar)
        .padding(.vertical, DesignTokens.Spacing.compact)
    }
}

// MARK: - Item text editor

/// A save failure the sheet shows, kept unresolved so it follows a language
/// switch made while the sheet is open.
private enum TextEditSheetError {
    case saveFailure(String)
    case richFormatUnsupported

    func message(language: AppLanguage) -> String {
        switch self {
        case .saveFailure(let message):
            return Localization.runtimeMessage(message, language: language)
        case .richFormatUnsupported:
            return Localization.string(.textEditRichFormatError, language: language)
        }
    }
}

/// Sheet for editing an entry's text or typing a new item.
///
/// A plain-text entry opens the plain editor, unchanged: saving keeps its
/// images, files, and itemsync base-name bookkeeping flavour, replaces the
/// plain-text flavours, and drops every other attachment that described the old
/// text. An HTML or RTF entry opens the styled editor instead, with the
/// toolbar's five attributes, and saves its document back in the format the
/// entry stores; a plain entry is never upgraded to a rich one. Creating a new
/// item writes the typed text as a new entry in the current tab.
private struct TextEditSheet: View {
    let request: PendingTextEdit
    let language: AppLanguage
    let onSave: (TextEditSubmission) -> String?
    let onCancel: () -> Void

    @State private var text: String
    /// The editor font fixed when the sheet opens, or nil while the preference
    /// is untouched so each editor keeps the font it drew with before the
    /// setting existed.
    ///
    /// The styled editor applies its base font while it loads the item, the way
    /// CopyQ sets the editor font before loading an entry's HTML, so a settings
    /// change mid-edit applies to the next item instead of restyling text the
    /// user is editing.
    @State private var editorFont: NSFont?
    @State private var error: TextEditSheetError?
    @StateObject private var richController = RichTextEditingController()

    init(
        request: PendingTextEdit,
        language: AppLanguage,
        font: FontPreference,
        onSave: @escaping (TextEditSubmission) -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.request = request
        self.language = language
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: request.text)
        _editorFont = State(initialValue: font.chosenFont)
    }

    private var canSave: Bool {
        if request.rich != nil { return richController.hasText }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var submission: TextEditSubmission {
        if request.rich != nil { return .styled(richController.document()) }
        return .text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
            Text(request.title(language: language))
                .font(.title3.weight(.semibold))

            if let detail = request.detailText(language: language) {
                Label {
                    Text(detail)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(DesignTokens.Typography.callout)
                .foregroundStyle(.secondary)
            }

            editor

            if let error {
                Text(error.message(language: language))
                    .font(DesignTokens.Typography.callout)
                    .foregroundStyle(DesignTokens.Colors.destructive)
            }

            HStack(spacing: DesignTokens.Spacing.medium) {
                if !canSave {
                    Text(Localization.string(.textEditEmptyWarning, language: language))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(Localization.string(.buttonCancel, language: language), role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(request.confirmTitle(language: language)) {
                    if let format = request.rich?.format,
                       !richController.isRepresentable(for: format) {
                        error = .richFormatUnsupported
                        return
                    }
                    error = onSave(submission).map { .saveFailure($0) }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
            }
        }
        .padding(DesignTokens.Spacing.xxLarge)
        .frame(minWidth: 540, minHeight: 380)
    }

    @ViewBuilder
    private var editor: some View {
        if let seed = request.rich {
            // The toolbar is part of the editor surface, so the controls and
            // the text they act on read as one panel.
            VStack(alignment: .leading, spacing: 0) {
                RichTextToolbar(controller: richController, language: language)
                Divider()
                RichTextEditor(
                    seed: seed.document,
                    format: seed.format,
                    font: editorFont,
                    controller: richController
                )
                    .frame(minHeight: 190, maxHeight: .infinity)
            }
            .padding(DesignTokens.Spacing.medium)
            .frame(minHeight: 220, maxHeight: .infinity)
            .glassSurface(cornerRadius: DesignTokens.Radius.card)
        } else {
            // The editor draws with the configured editor font (the app's body
            // font until one is chosen) and keeps its first line clear of the
            // clip; `TextEditor` clipped the tops of tall CJK glyphs there. See
            // `PlainTextEditor`.
            PlainTextEditor(text: $text, font: editorFont, focusOnAttach: true)
                .padding(DesignTokens.Spacing.medium)
                .frame(minHeight: 220, maxHeight: .infinity)
                .glassSurface(cornerRadius: DesignTokens.Radius.card)
        }
    }
}

// MARK: - Styled editing toolbar

/// Bold, italic, underline, colour, and size: the five attributes the item
/// editor stores, and nothing else.
///
/// The buttons reflect the attributes at the selection, so a mixed document
/// shows what the next action applies to. Bold, italic, and underline answer to
/// the standard shortcuts, which the text view itself handles
/// (`StyledTextView.formatCommand`).
private struct RichTextToolbar: View {
    @ObservedObject var controller: RichTextEditingController
    let language: AppLanguage

    private static let sizes: [Double] = [
        9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48, 64,
    ]

    private var availableSizes: [Double] {
        let current = controller.pointSize
        guard !Self.sizes.contains(current) else { return Self.sizes }
        return (Self.sizes + [current]).sorted()
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xSmall) {
            styleButton(
                "bold",
                help: Localization.string(.richToolbarBold, language: language),
                isOn: controller.isBold
            ) { controller.toggle(.bold) }
            styleButton(
                "italic",
                help: Localization.string(.richToolbarItalic, language: language),
                isOn: controller.isItalic
            ) { controller.toggle(.italic) }
            styleButton(
                "underline",
                help: Localization.string(.richToolbarUnderline, language: language),
                isOn: controller.isUnderline
            ) { controller.toggle(.underline) }

            Divider().frame(height: 16).padding(.horizontal, DesignTokens.Spacing.xSmall)

            ColorPicker(
                Localization.string(.richToolbarTextColour, language: language),
                selection: Binding(
                    get: { Color(nsColor: controller.color) },
                    set: { controller.apply(color: NSColor($0)) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 38)
            .help(Localization.string(.richToolbarTextColour, language: language))

            Button {
                controller.applyDefaultColor()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .help(Localization.string(.richToolbarDefaultColour, language: language))

            Divider().frame(height: 16).padding(.horizontal, DesignTokens.Spacing.xSmall)

            Picker(
                Localization.string(.richToolbarSize, language: language),
                selection: Binding(
                    get: { controller.pointSize },
                    set: { controller.apply(pointSize: $0) }
                )
            ) {
                ForEach(availableSizes, id: \.self) { size in
                    Text(Self.sizeLabel(size)).tag(size)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 84)
            .help(Localization.string(.richToolbarTextSize, language: language))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.xSmall)
        .padding(.vertical, DesignTokens.Spacing.compact)
    }

    private func styleButton(
        _ systemImage: String,
        help: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        // A tint keeps the glyph legible on the glass surface; a foreground
        // style lets SwiftUI draw a vibrant image that disappears there.
        .tint(isOn ? DesignTokens.Colors.selection : DesignTokens.Colors.label)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.tag, style: .continuous)
                .fill(isOn ? DesignTokens.Colors.selection.opacity(0.16) : Color.clear)
        )
        .help(help)
    }

    private static func sizeLabel(_ size: Double) -> String {
        size == size.rounded()
            ? "\(Int(size)) pt"
            : "\(size.formatted(.number.precision(.fractionLength(1)))) pt"
    }
}
