import AppKit
import SwiftUI

// MARK: - Layout B (Sidebar + Inspector)

struct LayoutBView: View {
    @ObservedObject var model: AppModel
    @FocusState.Binding var searchFocused: Bool
    let onDismiss: () -> Void

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isInspectorVisible = true
    @State private var noteFocused = false
    @State private var dragRatio: Double?
    @State private var sidebarWidth: CGFloat?
    @State private var sidebarDragBase: CGFloat?
    @State private var sidebarDebouncer = ColumnWidthDebouncer<SidebarLayout>()
    @State private var inspectorWidth: CGFloat?
    @State private var inspectorDragBase: CGFloat?
    @State private var inspectorDebouncer = ColumnWidthDebouncer<InspectorColumnLayout>()
    @State private var containerWidth: CGFloat = 0

    private var selectedEntry: ClipboardEntry? {
        guard let id = model.selection.selectedEntryID else { return nil }
        return model.entries.first { $0.id == id }
    }

    /// The sidebar column width the view currently renders. The stored width
    /// is the source of truth until the user drags the column's own edge, so
    /// the persisted width is restored on the first render after a relaunch.
    private var currentSidebarWidth: CGFloat {
        CGFloat(sidebarWidth ?? model.preferences.sidebarWidth)
    }

    /// The inspector column width the view currently renders. The stored width
    /// is the source of truth until the user drags the column's own edge, so
    /// the persisted width is restored on the first render after a relaunch.
    /// Clamped to the allowed range and to the container, so the center item
    /// list keeps at least 320 pt whenever the container is at least 560 pt
    /// wide; below that the inspector stays at its 240 pt minimum and the item
    /// list takes the remainder.
    private var currentInspectorWidth: CGFloat {
        let preferred = CGFloat(inspectorWidth ?? model.preferences.inspectorColumnWidth)
        return CGFloat(InspectorColumnLayout.clampWidth(Double(preferred), containerWidth: containerWidth))
    }

    var body: some View {
        let lang = model.preferences.language
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarTabView(model: model)
                .frame(width: currentSidebarWidth)
                .overlay(alignment: .trailing) {
                    SidebarResizeHandle(
                        width: $sidebarWidth,
                        dragBase: $sidebarDragBase,
                        storedWidth: model.preferences.sidebarWidth,
                        isVisible: columnVisibility != .detailOnly,
                        debouncer: sidebarDebouncer
                    ) { newWidth in
                        model.updatePreferences { $0.sidebarWidth = newWidth }
                    }
                }
                .navigationSplitViewColumnWidth(
                    min: currentSidebarWidth,
                    ideal: currentSidebarWidth,
                    max: currentSidebarWidth
                )
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
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                            }
                            .buttonStyle(.hover)
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
                    .buttonStyle(.hover)
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(Localization.string(.inspectorToggleHelp, language: lang))
                }
                .padding(.horizontal, DesignTokens.Spacing.bar)
                .frame(height: 52)

                Divider().opacity(0.35)

                // Center column + trailing inspector
                HStack(spacing: 0) {
                    ItemListView(model: model, maxTextLines: EntryRowMetrics.expandedMaxTextLines, onDismiss: onDismiss)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if isInspectorVisible {
                        Divider().opacity(0.35)

                        // Trailing inspector
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
                        .frame(width: currentInspectorWidth)
                        .overlay(alignment: .leading) {
                            InspectorResizeHandle(
                                width: $inspectorWidth,
                                dragBase: $inspectorDragBase,
                                renderedWidth: currentInspectorWidth,
                                storedWidth: model.preferences.inspectorColumnWidth,
                                isVisible: isInspectorVisible,
                                containerWidth: containerWidth,
                                debouncer: inspectorDebouncer
                            ) { newWidth in
                                model.updatePreferences { $0.inspectorColumnWidth = newWidth }
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { containerWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in
                                containerWidth = newWidth
                            }
                    }
                )

                Divider().opacity(0.35)
                StatusBarView(model: model)
            }
        }
        .toolbar {
            ToolbarItem(id: "SidebarToggleButton", placement: .navigation) {
                SidebarToggleButton(
                    columnVisibility: $columnVisibility,
                    language: lang
                )
                .background(ToolbarToggleAnchor())
            }
        }
        .onChange(of: model.focusNoteToken) { _, _ in noteFocused = true }
        .onChange(of: model.noteBlurToken) { _, _ in noteFocused = false }
        .onChange(of: isInspectorVisible) { _, visible in
            if !visible {
                inspectorDebouncer.cancel()
            }
        }
        .onChange(of: columnVisibility) { _, newVisibility in
            if newVisibility == .detailOnly {
                sidebarDebouncer.cancel()
            }
        }
        .onDisappear {
            sidebarDebouncer.cancel()
            inspectorDebouncer.cancel()
        }
    }
}
