import AppKit
import SwiftUI

// MARK: - Item list

struct ItemListView: View {
    @ObservedObject var model: AppModel
    var maxTextLines: Int = EntryRowMetrics.defaultMaxTextLines
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
                    maxTextLines: maxTextLines,
                    actions: EntryRowActions(
                        togglePin: { id in
                            guard let entry = model.entry(id: id) else { return }
                            model.togglePin(entry)
                        },
                        remove: { id in
                            guard let entry = model.entry(id: id) else { return }
                            model.remove(entry)
                        },
                        thumbnail: { id in model.rowThumbnail(for: id) },
                        entry: { id in model.entry(id: id) }
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
