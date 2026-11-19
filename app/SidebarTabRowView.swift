import AppKit
import SwiftUI

// MARK: - Sidebar Tab Row

struct SidebarTabRow: View {
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
                // The name is the row's elastic element: it takes the width the
                // row offers and truncates with an ellipsis when the name cannot
                // fit, so the count capsule stays pinned to the trailing edge.
                .frame(maxWidth: .infinity, alignment: .leading)

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
