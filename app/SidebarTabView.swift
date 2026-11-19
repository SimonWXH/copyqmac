import AppKit
import SwiftUI

// MARK: - Sidebar

struct SidebarTabView: View {
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
                        // A completed drag reorder can restore the moved row at
                        // the drag preview's content width, and the model update
                        // that follows is then a no-op for the List, so nothing
                        // lays the row out at the column width again. Keying the
                        // row by its position makes every reorder replace the
                        // row views whose position changed, which re-proposes
                        // the column width and discards any stale size the drop
                        // left behind.
                        .id(rowPosition(of: tab))
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
                .buttonStyle(.hover)
                .font(DesignTokens.Typography.caption)
                .help(Localization.string(.tabBarNewTabHelp, language: lang))

                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.vertical, DesignTokens.Spacing.small)
        }
    }

    /// The tab's current position in the sidebar, used as the row's view
    /// identity so a reorder recreates the rows whose position changed.
    private func rowPosition(of tab: ClipboardTab) -> Int {
        model.tabs.firstIndex { $0.id == tab.id } ?? -1
    }

    /// Runs the reorder the List's `.onMove` gesture reports. Internal so the
    /// layout tests can drive the shipped handler headlessly.
    func reorderTabs(from source: IndexSet, to destination: Int) {
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
