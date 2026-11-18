import AppKit
import SwiftUI

// MARK: - Tab Chip

struct TabChip: View {
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
            Button(titles.writeBackToSyncFolder) {
                model.requestWriteBackTab(tab.id)
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
